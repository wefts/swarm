defmodule Swarm.Graph.Network do
  @moduledoc """
  Network-map READ view (workspace ADR-17 world-map; substrate written by
  `Swarm.Enrichment.NetworkMap`). Reconstructs the topology skeleton at READ time from the
  namespaced `net:<kind>:<name>` `entity` nodes + their governed relation claim-edges — never a
  reified object (facts stay edges).

  **Provisional by construction** (blackboard council, the "ghost infrastructure" risk): Phase-1
  facts are prose-extracted `hypothesis`-kind edges at low reliability. This view is a discovery
  aid, NOT ground truth — it deliberately offers NO confident affordances (shortest-path,
  blast-radius, security-boundary) until Phase-2 (infra-as-code) evidence exists. Each relation
  carries its `reliability` + `seen_count` so the caller can weigh how well-attested it is.

  Scope-enforced on the entity endpoints AND the edge (`visibility_scope`); refuted edges
  (`reward < 0`) excluded, like every other read path. Network facts are clamped to `group` at
  write, so a `[public]` read never surfaces topology (no-leak).
  """

  alias Swarm.Graph.Freshness
  alias Swarm.Repo

  @typedoc "A network entity: its namespaced key, derived kind, and display name."
  @type entity :: %{key: String.t(), kind: String.t(), name: String.t()}

  @typedoc "A directed relation between two network entities, with attestation."
  @type relation :: %{
          src: String.t(),
          relation: String.t(),
          dst: String.t(),
          reliability: float(),
          seen_count: integer()
        }

  @doc """
  The network-map skeleton visible at `scopes`: `%{entities: [entity()], relations: [relation()]}`.
  Relations exclude the `is_a` typing edges (those are folded into each entity's `kind`). Empty
  when nothing is in scope. Ordered for stable rendering (entities by key; relations by
  reliability desc then key).
  """
  @spec map([String.t()]) :: %{entities: [entity()], relations: [relation()]}
  def map(scopes) when is_list(scopes) do
    %{entities: entities(scopes), relations: relations(scopes)}
  end

  def map(_), do: %{entities: [], relations: []}

  @doc "In-scope network entities (namespaced `net:<kind>:<name>` nodes)."
  @spec entities([String.t()]) :: [entity()]
  def entities([]), do: []

  def entities(scopes) when is_list(scopes) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT n.key
          FROM node n
         WHERE n.type = 'entity' AND n.scope = ANY($1) AND n.key LIKE 'net:%'
         ORDER BY n.key
        """,
        [scopes]
      )

    Enum.map(rows, fn [key] -> decode_key(key) end)
  end

  @doc "In-scope relation edges between network entities (excluding `is_a` typing edges)."
  @spec relations([String.t()]) :: [relation()]
  def relations([]), do: []

  def relations(scopes) when is_list(scopes) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT s.key, e.type, d.key, e.reliability, e.seen_count
          FROM edge e
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE e.type <> 'is_a' AND e.reward >= 0 AND e.visibility_scope = ANY($1)
           AND s.key LIKE 'net:%' AND d.key LIKE 'net:%'
           AND s.scope = ANY($1) AND d.scope = ANY($1)
         ORDER BY e.reliability DESC, s.key, e.type, d.key
        """,
        [scopes]
      )

    Enum.map(rows, fn [src, type, dst, rel, seen] ->
      %{
        src: strip_ns(src),
        relation: type,
        dst: strip_ns(dst),
        reliability: rel,
        seen_count: seen
      }
    end)
  end

  @stopwords ~w(the a an of to and or for with about how what which why who when where is are was
                were do does did can could should would from your you my our this that these those
                into out get set new list show tell me connected connect behind carried carry
                carries contains contain hosted host route routes via terminates)

  @doc """
  Network-entity CANDIDATE keys for a free-text query (for the tier-gate's `:network` path):
  in-scope `net:<kind>:<name>` entities whose name shares a significant term with the query AND
  that carry ≥1 non-`is_a`, non-refuted relation edge. Ranked by term-overlap, bounded. The gate
  probes these directly (like `Procedure.candidates/3`). `opts`: `:limit` (default 8).
  """
  @spec candidates(String.t(), [String.t()], keyword()) :: [String.t()]
  def candidates(query, scopes, opts \\ [])
  def candidates(_query, [], _opts), do: []

  def candidates(query, scopes, opts) when is_binary(query) and is_list(scopes) do
    limit = Keyword.get(opts, :limit, 8)
    terms = query_terms(query)

    if terms == [] do
      []
    else
      # match a term anywhere in the key (a mid-FQDN segment like "nebula" in
      # net:host:apt.nebula.intranet has no preceding colon), so the best-overlap entity wins
      likes = Enum.map(terms, &("%" <> &1 <> "%"))

      %{rows: rows} =
        Repo.query!(
          """
          SELECT ent.key,
                 (SELECT count(*) FROM unnest($3::text[]) t WHERE lower(ent.key) LIKE t) AS overlap
            FROM node ent
           WHERE ent.type = 'entity' AND ent.scope = ANY($1) AND ent.key LIKE 'net:%'
             AND lower(ent.key) LIKE ANY($3::text[])
             AND EXISTS (
               SELECT 1 FROM edge e
                WHERE e.src = ent.id AND e.type <> 'is_a' AND e.reward >= 0
                  AND e.visibility_scope = ANY($1)
             )
           ORDER BY overlap DESC, ent.key
           LIMIT $2
          """,
          [scopes, limit, likes]
        )

      Enum.map(rows, fn [key, _o] -> key end)
    end
  end

  @doc """
  The relation NEIGHBORHOOD of a network entity `key` (outgoing non-`is_a` edges), scope-enforced,
  refuted excluded. Each fact carries `corroboration` (distinct-lineage `seen_count`, S1). `opts`:
  `:min_corroboration` (default 1) — the tier-gate passes 2 to serve ONLY multi-source-confirmed
  topology; `:freshness` (default true) — S2: drop facts too STALE to serve (decay below the
  serve floor, per freshness class) and rank by `effective_reliability` (base × decay). Age is
  measured against the graph's freshness FRONTIER (newest `last_seen`) so a stalled ingest can't
  decay-then-escalate the whole graph. Returns `[%{relation, object, object_kind, corroboration,
  effective_reliability}]`, freshest-first.
  """
  @spec neighborhood(String.t(), [String.t()], keyword()) :: [map()]
  def neighborhood(key, scopes, opts \\ [])

  def neighborhood(_key, [], _opts), do: []

  def neighborhood(key, scopes, opts) when is_binary(key) and is_list(scopes) do
    min_corr = Keyword.get(opts, :min_corroboration, 1)
    freshness? = Keyword.get(opts, :freshness, true)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT e.type, d.key, e.seen_count, e.reliability::float8,
               extract(epoch FROM ((SELECT max(last_seen) FROM edge) - e.last_seen))::float8 AS age_sec
          FROM edge e
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE s.key = $1 AND e.type <> 'is_a' AND e.reward >= 0
           AND e.visibility_scope = ANY($2) AND d.scope = ANY($2) AND s.scope = ANY($2)
           AND e.seen_count >= $3
        """,
        [key, scopes, min_corr]
      )

    rows
    |> Enum.map(fn [type, dkey, seen, rel, age] ->
      age = age || 0.0
      %{
        relation: type,
        object: strip_ns(dkey),
        object_kind: decode_key(dkey).kind,
        corroboration: seen,
        effective_reliability: Freshness.effective_reliability(rel || 0.0, age, type),
        fresh?: Freshness.fresh?(age, type)
      }
    end)
    # S2 serve gate: drop too-stale facts (fail-closed — below-cutoff escalates, not served).
    |> then(fn facts -> if freshness?, do: Enum.filter(facts, & &1.fresh?), else: facts end)
    # rank freshest/most-reliable first, then corroboration
    |> Enum.sort_by(&{&1.effective_reliability, &1.corroboration}, :desc)
    |> Enum.map(&Map.delete(&1, :fresh?))
  end

  @spec query_terms(String.t()) :: [String.t()]
  defp query_terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stopwords))
    |> Enum.uniq()
  end

  # `net:<kind>:<name>` → %{key, kind, name}. A malformed key degrades gracefully to kind "entity".
  @spec decode_key(String.t()) :: entity()
  defp decode_key(key) do
    case String.split(key, ":", parts: 3) do
      ["net", kind, name] -> %{key: key, kind: kind, name: name}
      _ -> %{key: key, kind: "entity", name: strip_ns(key)}
    end
  end

  # `net:<kind>:<name>` → "<kind>/<name>" for compact rendering (or the raw key if malformed).
  @spec strip_ns(String.t()) :: String.t()
  defp strip_ns(key) do
    case String.split(key, ":", parts: 3) do
      ["net", kind, name] -> kind <> "/" <> name
      _ -> key
    end
  end
end
