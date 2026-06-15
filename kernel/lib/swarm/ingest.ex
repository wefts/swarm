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

  **Visibility on ingest (ADR-5).** Node scope comes from the event; default-deny
  is `private`. An edge inherits the **narrowest** scope of its two endpoints
  (deny-ordering `private < group < public`). The gate (Task 06) is the single
  enforcement point and pins which is authoritative.

  Performance: one transaction per event; node upserts and edge writes are each
  O(1) indexed-row ops — O(entities + relations) per event, no scan.
  """

  alias Swarm.Graph.Store
  alias Swarm.Ingest.Dedup

  require Logger

  @scope_rank %{"private" => 0, "group" => 1, "public" => 2}

  @doc """
  Ingest one normalized event map. Returns `{:ok, :written}`, `{:ok, :duplicate}`
  (provenance already seen), or a typed `{:error, reason}` (fail-loud).
  """
  @spec ingest(map()) :: {:ok, :written | :duplicate} | {:error, term()}
  def ingest(event) do
    with {:ok, norm} <- normalize(event) do
      if Dedup.seen?(norm.provenance) do
        {:ok, :duplicate}
      else
        :ok = write(norm)
        Dedup.mark(norm.provenance)
        {:ok, :written}
      end
    end
  end

  # --- normalization -------------------------------------------------------

  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  defp normalize(event) do
    with {:ok, provenance} <- fetch_string(event, :provenance),
         {:ok, occurred_at} <- to_utc(Map.get(event, :occurred_at)) do
      {:ok,
       %{
         provenance: provenance,
         occurred_at: occurred_at,
         entities: Enum.map(Map.get(event, :entities, []), &normalize_entity/1),
         relations: Enum.map(Map.get(event, :relations, []), &normalize_relation/1)
       }}
    end
  end

  @spec normalize_entity(map()) :: map()
  defp normalize_entity(e) do
    %{
      type: nfc(Map.fetch!(e, :type)),
      key: nfc(Map.fetch!(e, :key)),
      scope: Map.get(e, :scope, "private"),
      content: e |> Map.get(:content, "") |> nfc()
    }
  end

  @spec normalize_relation(map()) :: map()
  defp normalize_relation(r) do
    %{
      from: nfc(Map.fetch!(r, :from)),
      to: nfc(Map.fetch!(r, :to)),
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

  @spec fetch_string(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing, key}}
    end
  end

  # --- write ---------------------------------------------------------------

  @spec write(map()) :: :ok
  defp write(norm) do
    {:ok, :ok} =
      Swarm.Repo.transaction(fn ->
        ids = upsert_entities(norm.entities)
        scopes = Map.new(norm.entities, &{&1.key, &1.scope})
        Enum.each(norm.relations, &write_relation(&1, ids, scopes, norm.provenance))
        :ok
      end)

    :ok
  end

  @spec upsert_entities([map()]) :: %{optional(String.t()) => integer()}
  defp upsert_entities(entities) do
    Map.new(entities, fn e -> {e.key, Store.upsert_node(e.type, e.key, scope: e.scope)} end)
  end

  @spec write_relation(map(), map(), map(), String.t()) :: :ok
  defp write_relation(rel, ids, scopes, provenance) do
    case {Map.get(ids, rel.from), Map.get(ids, rel.to)} do
      {src, dst} when is_integer(src) and is_integer(dst) ->
        scope = narrowest(Map.get(scopes, rel.from), Map.get(scopes, rel.to))
        {:ok, _} = Store.add_edge(src, dst, rel.type, provenance, scope: scope)
        :ok

      _ ->
        # A relation referencing an entity not in this event is dropped with a
        # logged reason (no silent drop).
        Logger.warning("ingest: relation #{inspect(rel)} references unknown entity; dropped")
        :ok
    end
  end

  # Narrowest (deny-ordering) of two endpoint scopes; defaults to private.
  @spec narrowest(String.t() | nil, String.t() | nil) :: String.t()
  defp narrowest(a, b) do
    a = a || "private"
    b = b || "private"
    if Map.get(@scope_rank, a, 0) <= Map.get(@scope_rank, b, 0), do: a, else: b
  end
end
