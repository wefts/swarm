defmodule Swarm.Enrichment.WhoMap do
  @moduledoc """
  "Who is who" org-directory substrate writer (world-map master-plan E1; decorrelated review
  2026-07-07, codex + gemini — strong convergence). The SECOND world-map domain, sibling of
  `Swarm.Enrichment.NetworkMap` — but where NetworkMap extracts LOW-reliability topology HYPOTHESES
  from prose via an LLM, WhoMap writes HIGH-reliability AUTHORITATIVE facts from a structured
  host-side LDAP connector (no LLM, no extraction). The trust semantics differ, so the writers stay
  separate (rule of three — the generic writer is master-plan E2b, once ≥3 domains exist; both
  reviewers endorsed NOT extracting from two examples).

  ## Shape (mirrors NetworkMap's namespaced-entity design)
  - People/teams/roles/sites are plain `entity` nodes (never the `user` type — ADR-16 pins `user`
    private; org-directory people are group-scoped REFERENCE data), keyed `who:<kind>:<canonical>`
    (person by **uid**, the stable unique key — NOT name, so two "Jean Martin"s never collide;
    team/role/site by canonicalized ou/title/location). Each gets an `is_a` edge to a
    `concept:who:kind:<kind>` marker (queryable type, provenance-bearing).
  - **Governed relations** (closed by discipline): `managed_by` (person→person), `works_in`
    (person→team), `has_title` (person→role), `located_at` (person→site) — with relation↔kind
    signatures (a mis-typed edge is dropped, same conservative ethos as NetworkMap).
  - **Scope = group** for every who node/edge (org-internal reference; mirrors the directory's own
    in-network readability). Never public — a who fact never widens past `group` (no-leak).
  - **Profile as CONTENT** (`write_profile/3`): the allowlisted human attrs (cn/title/ou/l/mail/room)
    are stored as the person node's `content` body — SEARCHABLE, so "who is <Name>" resolves a name
    to the uid-keyed node (ER is OFF for persons — identity is uid, never name similarity). No PII
    beyond the ADR-16 allowlist; the connector never even fetches auth/system attrs.

  ## Staleness = RECONCILIATION, not decay (the review's BLOCKER fix)
  A monotonic claim-graph never REFUTES a departed/transferred person, so serving on a single
  authoritative lineage (`min_corroboration = 1`, reliability #{0.9}) would confidently answer with a
  leaver for weeks. The PRIMARY defense is **full-state reconciliation**: each directory refresh is a
  full REPLACE of the `ldap:directory` origin (purge its provenance + reap orphaned `who:` nodes,
  then rewrite the current snapshot — see `hive/scripts/who/load_who.exs`), so departures/moves
  vanish within one refresh cycle. Freshness/decay (org-membership relations = 30d `configuration`
  class) is only the BACKSTOP if the daily cron stops.
  """

  alias Swarm.Graph.Contract
  alias Swarm.Ingest.Content
  alias Swarm.Graph.Store
  alias Swarm.Repo

  @entity_type "entity"
  @marker_type "concept"
  @origin "ldap:directory"
  @lineage "ldap:directory"
  @reliability 0.9
  @evidence_kind "observation"

  # Governed who-kinds. Each becomes an `is_a` edge to a `concept:who:kind:<kind>` marker.
  @kinds ~w(person team role site)

  # Governed relation vocabulary (closed by discipline — an open relation set drifts into an
  # accidental schema via near-duplicates, NetworkMap's top anti-pattern).
  @relations ~w(managed_by works_in has_title located_at)

  # Relation↔endpoint-kind signatures: a fact whose endpoint kinds don't fit is DROPPED (a mis-typed
  # edge is worse than a missing one). `{subject_kinds, object_kinds}`.
  @signatures %{
    "managed_by" => {~w(person), ~w(person)},
    "works_in" => {~w(person), ~w(team)},
    "has_title" => {~w(person), ~w(role)},
    "located_at" => {~w(person), ~w(site)}
  }

  @segmenter "who-profile-v1"

  @typedoc "One org-structure fact: typed subject → relation → typed object (keys, pre-namespacing)."
  @type fact :: %{
          subject: String.t(),
          subject_kind: String.t(),
          relation: String.t(),
          object: String.t(),
          object_kind: String.t()
        }

  @doc "The authoritative directory origin these facts carry."
  @spec origin() :: String.t()
  def origin, do: @origin

  @doc "The governed who relation vocabulary (closed by discipline)."
  @spec relations() :: [String.t()]
  def relations, do: @relations

  @doc "The governed who-entity kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The namespaced entity key for a who node (`who:<kind>:<canonical>`)."
  @spec entity_key(String.t(), String.t()) :: String.t()
  def entity_key(kind, name), do: "who:" <> kind <> ":" <> normalize(name)

  @doc """
  Write `facts` (org-structure skeleton) as namespaced who `entity` nodes + `is_a` type edges + the
  governed relation claim-edges. Returns the fresh edge ids. Facts are signature-filtered
  (`admissible?/1`) — a mis-typed relation↔kind is dropped. `node` is the directory `source` anchor
  (a stable handle, never merged); every edge carries `source_node_id: node.id`, `origin`,
  `lineage`, `reliability` #{@reliability}, `evidence_kind` `#{@evidence_kind}`.

  `opts`: `:reliability`, `:evidence_kind`, `:origin`, `:lineage` (defaults above) — so a future
  second directory (preprod/replica) could load under a distinct origin and corroborate.
  """
  @spec write(map(), [fact()], String.t(), keyword()) :: [integer()]
  def write(node, facts, provenance, opts \\ []) do
    origin = Keyword.get(opts, :origin, @origin)
    lineage = Keyword.get(opts, :lineage, @lineage)
    reliability = Keyword.get(opts, :reliability, @reliability)
    evidence_kind = Keyword.get(opts, :evidence_kind, @evidence_kind)
    edge_opts = {reliability, evidence_kind, lineage}
    scope = who_scope(node.scope)

    facts
    |> Enum.filter(&admissible?/1)
    |> Enum.flat_map(fn fact ->
      subj = ensure_entity(fact.subject, fact.subject_kind, scope, node, origin, provenance, edge_opts)
      obj = ensure_entity(fact.object, fact.object_kind, scope, node, origin, provenance, edge_opts)

      case {subj, obj} do
        {{:ok, subj_id, subj_edges}, {:ok, obj_id, obj_edges}} ->
          rel_edges =
            emit_relation(subj_id, obj_id, fact.relation, scope, node, origin, provenance, edge_opts)

          subj_edges ++ obj_edges ++ rel_edges

        _ ->
          []
      end
    end)
  end

  @doc """
  Store an allowlisted person `profile` (a map with a required `"uid"` + optional cn/title/ou/l/
  mail/room) as the `who:person:<uid>` node's content body — SEARCHABLE so a name resolves to the
  uid-keyed node. Idempotent (1:1 content per node; re-writes the body). Returns the node id, or
  `:error` if the uid is missing/blank. Only the passed (allowlisted) fields are stored — the
  connector already excludes auth/system attrs at the source.
  """
  @spec write_profile(map(), String.t(), keyword()) :: integer() | :error
  def write_profile(profile, provenance, opts \\ [])

  def write_profile(%{"uid" => uid} = profile, _provenance, opts) when is_binary(uid) do
    scope = who_scope(Keyword.get(opts, :scope, "group"))
    key = entity_key("person", uid)

    if String.trim(uid) == "" do
      :error
    else
      node_id = Store.upsert_node(@entity_type, key, scope: scope)
      body = profile_body(profile)

      Repo.query!(
        """
        INSERT INTO content (node_id, body, body_hash, segmenter)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (node_id) DO UPDATE SET body = EXCLUDED.body, body_hash = EXCLUDED.body_hash
        """,
        [node_id, body, Content.body_hash(body), @segmenter]
      )

      node_id
    end
  end

  def write_profile(_profile, _provenance, _opts), do: :error

  @doc "Is a directly-fed fact well-typed (vocab + relation↔kind signature)?"
  @spec admissible?(fact()) :: boolean()
  def admissible?(%{subject_kind: sk, relation: rel, object_kind: ok} = f)
      when is_binary(sk) and is_binary(rel) and is_binary(ok) do
    subj = Map.get(f, :subject)
    obj = Map.get(f, :object)

    rel in @relations and sk in @kinds and ok in @kinds and valid_signature?(rel, sk, ok) and
      is_binary(subj) and String.trim(subj) != "" and
      is_binary(obj) and String.trim(obj) != "" and
      not (sk == ok and normalize(subj) == normalize(obj))
  end

  def admissible?(_), do: false

  # --- write helpers ---------------------------------------------------------

  @spec ensure_entity(
          String.t(),
          String.t(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          {float(), String.t(), String.t() | nil}
        ) :: {:ok, integer(), [integer()]} | :error
  defp ensure_entity(name, kind, scope, node, origin, provenance, {reliability, evidence_kind, lineage}) do
    ent = Store.upsert_node(@entity_type, entity_key(kind, name), scope: scope)
    # Kind markers are generic, non-sensitive type labels — pinned at `group` so the is_a edge's
    # visibility invariant (edge scope ≤ min endpoints) holds for the group-scoped entity.
    marker = Store.upsert_node(@marker_type, "who:kind:" <> kind, scope: "group")

    case Store.add_edge(ent, marker, "is_a", provenance,
           scope: scope,
           origin: origin,
           lineage: lineage,
           reliability: reliability,
           evidence_kind: evidence_kind,
           source_node_id: node.id
         ) do
      {:ok, %{id: id}} -> {:ok, ent, [id]}
      {:error, _} -> :error
    end
  end

  @spec emit_relation(
          integer(),
          integer(),
          String.t(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          {float(), String.t(), String.t() | nil}
        ) :: [integer()]
  defp emit_relation(src, dst, relation, scope, node, origin, provenance, {reliability, evidence_kind, lineage}) do
    case Store.add_edge(src, dst, relation, provenance,
           scope: scope,
           origin: origin,
           lineage: lineage,
           reliability: reliability,
           evidence_kind: evidence_kind,
           source_node_id: node.id
         ) do
      {:ok, %{id: id}} -> [id]
      {:error, _} -> []
    end
  end

  # who scope clamp: never wider than `group` (org-directory reference is group-internal; a who fact
  # never mints a public node — no-leak). A narrower source scope is preserved.
  @spec who_scope(String.t()) :: String.t()
  defp who_scope(source_scope) do
    if Contract.scope_rank(source_scope) > Contract.scope_rank("group"),
      do: "group",
      else: source_scope
  end

  @spec valid_signature?(String.t(), String.t(), String.t()) :: boolean()
  defp valid_signature?(rel, sk, ok) do
    case Map.get(@signatures, rel) do
      {subj_kinds, obj_kinds} -> sk in subj_kinds and ok in obj_kinds
      nil -> false
    end
  end

  # Render the allowlisted profile as a compact, searchable content body. Only known fields, in a
  # stable order; blank fields skipped. This is the ONLY place person attrs become text.
  @spec profile_body(map()) :: String.t()
  defp profile_body(profile) do
    [
      {"name", profile["cn"]},
      {"given_name", profile["given_name"]},
      {"surname", profile["sn"]},
      {"title", profile["title"]},
      {"team", profile["ou"]},
      {"department", profile["department"]},
      {"org", profile["o"]},
      {"location", profile["l"]},
      {"mail", profile["mail"]},
      {"room", profile["room"]},
      {"uid", profile["uid"]}
    ]
    |> Enum.filter(fn {_k, v} -> is_binary(v) and String.trim(v) != "" end)
    |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp normalize(s), do: s |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
end
