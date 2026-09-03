defmodule Swarm.Ingest do
  @moduledoc """
  Kernel-side ingestion (Domain 2): normalize an external event map and write
  nodes + typed edges. Connectors live outside the kernel; this is the single
  boundary where their events enter the graph, and where the boundary invariants
  are enforced:

  - **tz-aware UTC** — `occurred_at` must be a UTC `DateTime` or an ISO-8601
    string with an offset; a naive timestamp is rejected, never stamped as UTC.
  - **NFC Unicode** — all text is NFC-normalized; no lossy ASCII folding (keeps
    Cyrillic/CJK identifiers intact).
  - **dedup** — a cheap provenance-key pre-filter (`Dedup`) skips repeats; the DB
    upsert (node identity key + edge provenance guard) is the authoritative,
    restart-durable dedup, so a duplicate event never double-writes.
  - **evidential origin** (workspace ADR-13) — an event may carry a stable
    `origin` (the source identity, distinct from the per-event `provenance`);
    every relation in the event shares it, so N derivative events of one source
    reinforce an edge once, not N times. Absent ⇒ defaults to `provenance`.
  - **entity identity vs display key** — an entity may carry `identity` (or
    `source_ref`) as its stable graph key while keeping `key` as the human-readable
    display title. Relations may use `from_ref`/`to_ref` to target those stable
    identities; absent refs fall back to the legacy `from`/`to` title fields.

  **Visibility on ingest (ADR-5).** Node scope comes from the event; default-deny
  is `private`. An edge inherits the greatest lower bound of its two endpoints
  in the Contract scope lattice. The gate (Task 06) is the single enforcement
  point and pins which is authoritative.

  Performance: one transaction per event; node upserts and edge writes are each
  O(1) indexed-row ops — O(entities + relations) per event, no scan.
  """

  alias Swarm.Graph.Contract
  alias Swarm.Graph.Store
  alias Swarm.Graph.Temporal
  alias Swarm.Ingest.Content
  alias Swarm.Ingest.DeadLetter
  alias Swarm.Ingest.Dedup
  alias Swarm.Repo

  require Logger

  @doc """
  Ingest one normalized event map. Returns `{:ok, :written}`, `{:ok, :duplicate}`
  (provenance already seen), or a typed `{:error, reason}` (fail-loud).
  """
  @spec ingest(map()) :: {:ok, :written | :duplicate} | {:error, {:quarantined, term()}}
  def ingest(event) do
    case normalize(event) do
      {:error, reason} -> quarantine(event, reason)
      {:ok, norm} -> ingest_normalized(event, norm)
    end
  end

  @spec ingest_normalized(map(), map()) ::
          {:ok, :written | :duplicate} | {:error, {:quarantined, term()}}
  defp ingest_normalized(event, norm) do
    if Dedup.seen?(norm.provenance) do
      {:ok, :duplicate}
    else
      case write(norm) do
        :ok ->
          Dedup.mark(norm.provenance)
          {:ok, :written}

        {:error, reason} ->
          quarantine(event, reason)
      end
    end
  end

  # A poison trace → the dead-letter zone (T10), with its reason. The pipeline
  # keeps running; the event is recorded, never silently dropped, never re-entered.
  @spec quarantine(map(), term()) :: {:error, {:quarantined, term()}}
  defp quarantine(event, reason) do
    DeadLetter.quarantine(event, reason)
    {:error, {:quarantined, reason}}
  end

  # --- normalization -------------------------------------------------------

  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  defp normalize(event) do
    with {:ok, provenance} <- fetch_string(event, :provenance),
         {:ok, occurred_at} <- to_utc(Map.get(event, :occurred_at)),
         {:ok, valid_time} <- optional_utc(Map.get(event, :valid_time)),
         :ok <- check_registered_sources(event) do
      {:ok,
       %{
         provenance: provenance,
         # Evidential origin (workspace ADR-13): the STABLE source identity a
         # connector derives from content (same fact re-emitted ⇒ same origin),
         # distinct from the per-event `provenance` (emission instance). It is what
         # reinforcement/corroboration count distinct instances of, so N derivative
         # events of one source do not over-corroborate. Absent ⇒ defaults to
         # `provenance` (every event its own origin = pre-ADR-13 behaviour); a
         # derivative-capable connector SHOULD supply it (see `ports.md`).
         origin: origin(event, provenance),
         occurred_at: occurred_at,
         # Temporal model (schema v13): `valid_time` is the SOURCE truth time of the event's state
         # relations (a live API's observation instant, a commit time…), distinct from
         # `occurred_at`/ingest time. Absent ⇒ the relations are asserted UNDATED — never stamped
         # with ingest time. `source` names the asserting run (site-qualified, e.g.
         # `proxmox:casa`) so a live source can later close what it stopped returning.
         valid_time: valid_time,
         source: optional_string(Map.get(event, :source)),
         entities: Enum.map(Map.get(event, :entities, []), &normalize_entity/1),
         relations: Enum.map(Map.get(event, :relations, []), &normalize_relation/1)
       }}
    end
  end

  @spec optional_utc(term()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  defp optional_utc(nil), do: {:ok, nil}
  defp optional_utc(""), do: {:ok, nil}
  defp optional_utc(value), do: to_utc(value)

  @spec optional_string(term()) :: String.t() | nil
  defp optional_string(s) when is_binary(s) and s != "", do: nfc(s)
  defp optional_string(_), do: nil

  # ADR-20 §3: a `src:*` scope must name a REGISTERED Source (`Swarm.Projects`) — a connector
  # cannot invent a scope, and no row is ever written under a coordinate nobody can derive
  # (that would be a silent, unreadable write). Base scopes (`public`/`private`) pass; a
  # malformed or unknown source scope quarantines the whole event, fail-loud.
  @spec check_registered_sources(map()) :: :ok | {:error, {:unregistered_source_scope, term()}}
  defp check_registered_sources(event) do
    event
    |> Map.get(:entities, [])
    |> Enum.map(&Map.get(&1, :scope, "private"))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in Contract.scopes()))
    |> Enum.find(fn scope -> not Swarm.Projects.registered_scope?(scope) end)
    |> case do
      nil -> :ok
      bad -> {:error, {:unregistered_source_scope, bad}}
    end
  end

  @spec origin(map(), String.t()) :: String.t()
  defp origin(event, provenance) do
    case Map.get(event, :origin) do
      o when is_binary(o) and o != "" ->
        nfc(o)

      _ ->
        # Compatibility fallback (not silent): a derivative-capable connector that
        # omits `origin` re-opens the ADR-13 correlated-evidence hazard, so the
        # degradation is logged, tagged by source, never quietly applied.
        Logger.warning(
          "ingest: event from source=#{inspect(Map.get(event, :source))} has no evidential " <>
            "origin; defaulting origin:=provenance (ADR-13) — derivative-capable connectors must set origin"
        )

        provenance
    end
  end

  @spec normalize_entity(map()) :: map()
  defp normalize_entity(e) do
    key = nfc(Map.fetch!(e, :key))
    identity = e |> entity_identity(key) |> nfc()
    source_ref = optional_nfc(Map.get(e, :source_ref))

    %{
      type: nfc(Map.fetch!(e, :type)),
      key: key,
      identity: identity,
      source_ref: source_ref,
      scope: Map.get(e, :scope, "private"),
      content: e |> Map.get(:content, "") |> nfc()
    }
  end

  @spec entity_identity(map(), String.t()) :: String.t()
  defp entity_identity(e, fallback) do
    cond do
      is_binary(Map.get(e, :identity)) and Map.get(e, :identity) != "" ->
        Map.get(e, :identity)

      is_binary(Map.get(e, :source_ref)) and Map.get(e, :source_ref) != "" ->
        Map.get(e, :source_ref)

      true ->
        fallback
    end
  end

  @spec normalize_relation(map()) :: map()
  defp normalize_relation(r) do
    %{
      from: nfc(Map.fetch!(r, :from)),
      to: nfc(Map.fetch!(r, :to)),
      from_ref: r |> Map.get(:from_ref, Map.fetch!(r, :from)) |> nfc(),
      to_ref: r |> Map.get(:to_ref, Map.fetch!(r, :to)) |> nfc(),
      type: nfc(Map.fetch!(r, :type))
    }
  end

  # tz-aware UTC at the boundary: accept a UTC DateTime or an offset-bearing
  # ISO-8601 string; reject naive time (fail loud — never stamp naive as UTC).
  @spec to_utc(term()) :: {:ok, DateTime.t()} | {:error, term()}
  defp to_utc(%DateTime{time_zone: "Etc/UTC"} = dt), do: {:ok, dt}
  defp to_utc(%DateTime{} = dt), do: {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

  defp to_utc(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:bad_timestamp, reason}}
    end
  end

  defp to_utc(other), do: {:error, {:bad_timestamp, other}}

  @spec nfc(String.t()) :: String.t()
  defp nfc(s) when is_binary(s), do: :unicode.characters_to_nfc_binary(s)

  @spec optional_nfc(term()) :: String.t() | nil
  defp optional_nfc(s) when is_binary(s) and s != "", do: nfc(s)
  defp optional_nfc(_), do: nil

  @spec fetch_string(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing, key}}
    end
  end

  # --- write ---------------------------------------------------------------

  # `:ok`, or `{:error, reason}` if the write hits a graph-contract violation
  # (ADR-4) — a malformed type/scope is a poison trace, NOT a kernel crash. The
  # whole event's tx rolls back so a bad relation never half-writes.
  @spec write(map()) :: :ok | {:error, term()}
  defp write(norm) do
    result =
      Swarm.Repo.transaction(fn ->
        ids = upsert_entities(norm.entities)
        persist_content(norm.entities, ids, norm.provenance)
        scopes = refs_to_scopes(norm.entities, ids)
        write_relations(norm.relations, ids, scopes, norm)
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A graph-contract violation (ADR-4) is POISON → quarantine. The rescue is
    # specific (`ContractError`, not bare `ArgumentError`) so a real bug still
    # crashes loud. A transport failure (Postgrex/DBConnection) is NOT poison —
    # it is transient and deliberately propagates (the not-found-vs-outage rule).
    e in [Swarm.Graph.ContractError] -> {:error, {:contract, e.reason}}
  end

  @spec upsert_entities([map()]) :: %{optional(String.t()) => integer()}
  defp upsert_entities(entities) do
    entities
    |> Enum.map(fn e ->
      id = Store.upsert_node(e.type, e.identity, scope: e.scope, display_key: e.key)
      {e, id}
    end)
    |> refs_to_ids()
  end

  @spec refs_to_ids([{map(), integer()}]) :: %{optional(String.t()) => integer()}
  defp refs_to_ids(entity_ids) do
    Enum.reduce(entity_ids, %{}, fn {e, id}, acc ->
      acc
      |> Map.put(e.identity, id)
      |> Map.put(e.key, id)
    end)
  end

  # The scope an edge may take is bounded by its endpoints AS STORED, not only as declared: an
  # entity that already exists under another source's scope (a cluster the IaC source named
  # first, a shared marker) keeps that scope on upsert, and the contract checks the stored
  # value. Clamping to GLB(declared, stored) lands the cross-source edge as `private` (the
  # ADR-18 F3 cost) instead of quarantining the whole event as scope_wider_than_endpoints.
  @spec refs_to_scopes([map()], map()) :: %{optional(String.t()) => String.t()}
  defp refs_to_scopes(entities, ids) do
    stored = stored_scopes(Map.values(ids))

    Enum.reduce(entities, %{}, fn e, acc ->
      scope = Contract.glb(e.scope, Map.get(stored, Map.get(ids, e.identity), e.scope))

      acc
      |> Map.put(e.identity, scope)
      |> Map.put(e.key, scope)
    end)
  end

  @spec stored_scopes([integer()]) :: %{optional(integer()) => String.t()}
  defp stored_scopes([]), do: %{}

  defp stored_scopes(node_ids) do
    %{rows: rows} =
      Repo.query!("SELECT id, scope FROM node WHERE id = ANY($1)", [Enum.uniq(node_ids)])

    Map.new(rows, fn [id, scope] -> {id, scope} end)
  end

  # Persist each content-bearing entity's raw body (swarm ADR-14 §2, Phase A):
  # deterministic, in-tx, no network. Embedding (segment → chunk → node.vec) is
  # the separate worker step (`Content.embed/2`) reacting to the `content_added`
  # signal — kept OUT of this transaction so the gRPC embed call never holds a
  # graph lock open. A blank body is skipped.
  @spec persist_content([map()], map(), String.t()) :: :ok
  defp persist_content(entities, ids, provenance) do
    Enum.each(entities, fn e ->
      with id when is_integer(id) <- Map.get(ids, e.identity),
           body when is_binary(body) <- Map.get(e, :content, "") do
        Content.put_body(id, body, source_ref: e.source_ref || provenance)
      end
    end)

    :ok
  end

  # Write every relation in the event's transaction; a contract rejection on any
  # one rolls the whole event back (so it quarantines, not half-writes). All
  # relations in one event share the event's evidential `origin` (the source that
  # asserts them).
  @spec write_relations([map()], map(), map(), map()) :: :ok
  defp write_relations(relations, ids, scopes, norm) do
    Enum.each(relations, fn rel ->
      case write_relation(rel, ids, scopes, norm) do
        :ok -> :ok
        {:error, reason} -> Swarm.Repo.rollback(reason)
      end
    end)

    :ok
  end

  @spec write_relation(map(), map(), map(), map()) :: :ok | {:error, term()}
  defp write_relation(rel, ids, scopes, norm) do
    %{provenance: provenance, origin: origin} = norm

    case {Map.get(ids, rel.from_ref), Map.get(ids, rel.to_ref)} do
      {src, dst} when is_integer(src) and is_integer(dst) ->
        scope = narrowest(Map.get(scopes, rel.from_ref), Map.get(scopes, rel.to_ref))

        with {:ok, %{id: edge_id}} <-
               Store.add_edge(src, dst, rel.type, provenance, scope: scope, origin: origin),
             # Validity interval (schema v13) — a no-op unless the registry declares the relation
             # a `:state`. The asserting `source` defaults to the origin when the event names none.
             {:ok, _} <-
               Temporal.assert(edge_id,
                 valid_time: norm.valid_time,
                 source: norm.source || origin,
                 origin: origin
               ) do
          :ok
        end

      _ ->
        # A relation referencing an entity not in this event is dropped with a
        # logged reason (no silent drop).
        Logger.warning("ingest: relation #{inspect(rel)} references unknown entity; dropped")
        :ok
    end
  end

  # The edge's scope is the greatest lower bound of its two endpoint scopes (lattice; ADR-18 F1).
  @spec narrowest(String.t() | nil, String.t() | nil) :: String.t()
  defp narrowest(a, b), do: Contract.glb(a || "private", b || "private")
end
