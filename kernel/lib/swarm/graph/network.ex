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

  @candidate_relations ~w(contains hosted_on routes_via egresses_via connects_site terminates_at protected_by alias_of carries has_address has_private_address has_public_address has_outbound_ip_address contained_by routes_for terminates_for)

  @cardinality %{
    "contains" => :many,
    "hosted_on" => :single,
    "routes_via" => :many,
    "egresses_via" => :many,
    "connects_site" => :many,
    "terminates_at" => :many,
    "protected_by" => :many,
    "alias_of" => :many,
    "carries" => :many,
    "has_address" => :many,
    "has_private_address" => :many,
    "has_public_address" => :many,
    "has_outbound_ip_address" => :many,
    "contained_by" => :many,
    "routes_for" => :many,
    "terminates_for" => :many
  }

  @doc "Declared cardinality for network relations; unknown relations are many-valued."
  @spec cardinality(String.t()) :: :single | :many
  def cardinality(relation), do: Map.get(@cardinality, relation, :many)

  @stopwords ~w(the a an of to and or for with about how what which why who when where is are was
                were do does did can could should would from your you my our this that these those
                into out get set new list show tell me connected connect behind carried carry
                carries contains contain hosted host route routes via terminates public private
                internal external address addresses ip ips)

  @doc """
  Network-bearing CANDIDATE keys for a free-text query (for the tier-gate's `:network` path):
  in-scope entities whose name shares a significant term with the query AND that carry ≥1 governed
  network relation edge. Most are namespaced `net:<kind>:<name>` nodes, but document-extracted
  service/runner entities can also own direct address facts (`has_outbound_ip_address`). Ranked by
  term-overlap, bounded. The gate probes these directly (like `Procedure.candidates/3`). `opts`:
  `:limit` (default 8).
  """
  @spec candidates(String.t(), [String.t()], keyword()) :: [String.t()]
  def candidates(query, scopes, opts \\ [])
  def candidates(_query, [], _opts), do: []

  def candidates(query, scopes, opts) when is_binary(query) and is_list(scopes) do
    limit = Keyword.get(opts, :limit, 8)
    terms = query_terms(query)
    qvec = query_vec(opts)

    lexical =
      if terms == [] do
        []
      else
        lexical_candidates(terms, scopes, limit)
      end

    exact = exact_literal_candidates(query, scopes, limit)
    vector = if qvec, do: vector_candidates(qvec, scopes, limit), else: []
    Enum.uniq(exact ++ lexical ++ vector) |> Enum.take(limit)
  end

  defp exact_literal_candidates(query, scopes, limit) do
    literals =
      query
      |> network_literals()
      |> Enum.flat_map(fn literal ->
        ["net:address:#{literal}", "net:subnet:#{literal}", "net:gateway:#{literal}"]
      end)
      |> Enum.uniq()

    if literals == [] do
      []
    else
      %{rows: rows} =
        Repo.query!(
          """
          SELECT n.key
            FROM node n
           WHERE n.type = 'entity'
             AND n.scope = ANY($1)
             AND n.key = ANY($2)
           ORDER BY CASE
                      WHEN n.key LIKE 'net:gateway:%' THEN 0
                      WHEN n.key LIKE 'net:address:%' THEN 1
                      ELSE 2
                    END,
                    n.key
           LIMIT $3
          """,
          [scopes, literals, limit]
        )

      Enum.map(rows, fn [key] -> key end)
    end
  end

  defp lexical_candidates(terms, scopes, limit) do
    # match a term anywhere in the key (a mid-FQDN segment like "nebula" in
    # net:host:apt.nebula.intranet has no preceding colon), so the best-overlap entity wins
    likes = Enum.map(terms, &("%" <> &1 <> "%"))

    %{rows: rows} =
      Repo.query!(
        """
        SELECT ent.key,
               (SELECT count(*) FROM unnest($3::text[]) t WHERE lower(ent.key) LIKE t) AS overlap,
               CASE WHEN ent.key LIKE 'net:%' THEN 1 ELSE 0 END AS is_net
          FROM node ent
         WHERE ent.type = 'entity' AND ent.scope = ANY($1)
           AND lower(ent.key) LIKE ANY($3::text[])
           AND EXISTS (
             SELECT 1 FROM edge e
              WHERE e.src = ent.id AND e.type = ANY($4) AND e.reward >= 0
                AND e.visibility_scope = ANY($1)
           )
         ORDER BY overlap DESC, is_net ASC, ent.key
         LIMIT $2
        """,
        [scopes, limit, likes, @candidate_relations]
      )

    Enum.map(rows, fn [key, _overlap, _is_net] -> key end)
  end

  defp vector_candidates(qvec, scopes, limit) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT ent.key
          FROM node ent
         WHERE ent.type = 'entity' AND ent.scope = ANY($1)
           AND ent.vec IS NOT NULL
           AND EXISTS (
             SELECT 1 FROM edge e
              WHERE e.src = ent.id AND e.type = ANY($3) AND e.reward >= 0
                AND e.visibility_scope = ANY($1)
           )
         ORDER BY ent.vec <=> $4
         LIMIT $2
        """,
        [scopes, limit, @candidate_relations, qvec]
      )

    direct = Enum.map(rows, fn [key] -> key end)

    seed_terms =
      qvec
      |> vector_seed_keys(scopes, min(limit, 6))
      |> Enum.flat_map(&query_terms/1)

    Enum.uniq(lexical_candidates(seed_terms, scopes, limit) ++ direct)
  end

  defp vector_seed_keys(qvec, scopes, limit) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT n.key
          FROM node n
         WHERE n.scope = ANY($1) AND n.vec IS NOT NULL
         ORDER BY n.vec <=> $3
         LIMIT $2
        """,
        [scopes, limit, qvec]
      )

    Enum.map(rows, fn [key] -> key end)
  end

  @doc """
  The relation NEIGHBORHOOD of a network entity `key` (outgoing non-`is_a` edges), scope-enforced,
  refuted excluded. Each fact carries `corroboration` (distinct-lineage `seen_count`, S1). `opts`:
  `:min_corroboration` (default 1) — the tier-gate passes 2 to serve ONLY multi-source-confirmed
  topology; `:freshness` (default true) — S2: drop facts too STALE to serve (decay below the
  serve floor, per freshness class) and rank by `effective_reliability` (base × decay). Age is
  measured against the relation's freshness-class FRONTIER (newest `last_seen` in that class) so a
  stalled ingest can't decay-then-escalate the whole graph, and fresh structural derivations don't
  stale-out older configuration facts. Returns `[%{relation, object, object_kind, corroboration,
  effective_reliability}]`, freshest-first.
  """
  @spec neighborhood(String.t(), [String.t()], keyword()) :: [map()]
  def neighborhood(key, scopes, opts \\ [])

  def neighborhood(_key, [], _opts), do: []

  def neighborhood(key, scopes, opts) when is_binary(key) and is_list(scopes) do
    min_corr = Keyword.get(opts, :min_corroboration, 1)
    freshness? = Keyword.get(opts, :freshness, true)
    relation_filter = Keyword.get(opts, :relations)
    edge_class = Freshness.sql_class_case("e.type")
    frontier_class = Freshness.sql_class_case("ef.type")
    address_children = ~w(has_private_address has_public_address)

    %{rows: rows} =
      Repo.query!(
        """
        WITH freshness_frontier AS (
          SELECT #{frontier_class} AS freshness_class,
                 max(ef.last_seen) AS last_seen
            FROM edge ef
           GROUP BY 1
        )
        SELECT e.type, d.key, d.net_address_class, e.seen_count, e.reliability::float8,
               extract(epoch FROM (ff.last_seen - e.last_seen))::float8 AS age_sec
          FROM edge e
          JOIN freshness_frontier ff ON ff.freshness_class = #{edge_class}
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE s.key = $1 AND e.type <> 'is_a' AND e.reward >= 0
           AND e.visibility_scope = ANY($2) AND d.scope = ANY($2) AND s.scope = ANY($2)
           AND e.seen_count >= $3
           AND ($4::text[] IS NULL OR e.type = ANY($4))
           AND ($4::text[] IS NOT NULL OR e.type <> ALL($5))
        """,
        [key, scopes, min_corr, relation_filter, address_children]
      )

    facts =
      rows
      |> Enum.map(&fact_from_row/1)
      |> Kernel.++(containment_facts(key, scopes, min_corr, relation_filter))
      |> Kernel.++(reverse_gateway_facts(key, scopes, min_corr, relation_filter))
      |> Kernel.++(reverse_termination_facts(key, scopes, min_corr, relation_filter))

    facts
    # S2 serve gate: drop too-stale facts (fail-closed — below-cutoff escalates, not served).
    |> then(fn facts -> if freshness?, do: Enum.filter(facts, & &1.fresh?), else: facts end)
    # rank freshest/most-reliable first, then corroboration
    |> Enum.sort_by(&{&1.effective_reliability, &1.corroboration}, :desc)
    |> Enum.map(&Map.delete(&1, :fresh?))
  end

  defp containment_facts(_key, _scopes, _min_corr, [_ | _]), do: []

  defp containment_facts(key, scopes, min_corr, _relation_filter) do
    edge_class = Freshness.sql_class_case("e.type")
    frontier_class = Freshness.sql_class_case("ef.type")

    %{rows: rows} =
      Repo.query!(
        """
        WITH subject AS (
          SELECT id, key, net_addr, scope
            FROM node
           WHERE key = $1 AND scope = ANY($2) AND net_addr IS NOT NULL
        ),
        freshness_frontier AS (
          SELECT #{frontier_class} AS freshness_class,
                 max(ef.last_seen) AS last_seen
            FROM edge ef
           GROUP BY 1
        )
        SELECT 'contained_by'::text, subnet.key, subnet.net_address_class,
               max(e.seen_count) AS seen_count, max(e.reliability)::float8 AS reliability,
               extract(epoch FROM (max(ff.last_seen) - max(e.last_seen)))::float8 AS age_sec
          FROM subject s
          JOIN node subnet ON subnet.scope = ANY($2)
                          AND subnet.key LIKE 'net:subnet:%'
                          AND subnet.net_range IS NOT NULL
                          AND s.net_addr <<= subnet.net_range
          JOIN edge e ON e.dst = subnet.id
                     AND e.reward >= 0
                     AND e.visibility_scope = ANY($2)
                     AND e.seen_count >= $3
          JOIN freshness_frontier ff ON ff.freshness_class = #{edge_class}
         GROUP BY subnet.key, subnet.net_address_class
        """,
        [key, scopes, min_corr]
      )

    Enum.map(rows, &fact_from_row/1)
  end

  defp reverse_gateway_facts("net:gateway:" <> _ = key, scopes, min_corr, relation_filter) do
    if routes_for_filtered_out?(relation_filter) do
      []
    else
      reverse_gateway_facts_for_gateway(key, scopes, min_corr)
    end
  end

  defp reverse_gateway_facts(_key, _scopes, _min_corr, _relation_filter), do: []

  defp routes_for_filtered_out?(relations) when is_list(relations),
    do: "routes_for" not in relations

  defp routes_for_filtered_out?(_), do: false

  defp reverse_gateway_facts_for_gateway(key, scopes, min_corr) do
    edge_class = Freshness.sql_class_case("e.type")
    frontier_class = Freshness.sql_class_case("ef.type")

    %{rows: rows} =
      Repo.query!(
        """
        WITH freshness_frontier AS (
          SELECT #{frontier_class} AS freshness_class,
                 max(ef.last_seen) AS last_seen
            FROM edge ef
           GROUP BY 1
        )
        SELECT 'routes_for'::text, s.key, s.net_address_class, e.seen_count, e.reliability::float8,
               extract(epoch FROM (ff.last_seen - e.last_seen))::float8 AS age_sec
          FROM edge e
          JOIN freshness_frontier ff ON ff.freshness_class = #{edge_class}
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE d.key = $1
           AND e.type = 'routes_via'
           AND e.reward >= 0
           AND e.visibility_scope = ANY($2)
           AND s.scope = ANY($2)
           AND d.scope = ANY($2)
           AND e.seen_count >= $3
         ORDER BY e.reliability DESC, s.key
         LIMIT 30
        """,
        [key, scopes, min_corr]
      )

    Enum.map(rows, &fact_from_row/1)
  end

  defp reverse_termination_facts("net:gateway:" <> _ = key, scopes, min_corr, relation_filter) do
    if terminates_for_filtered_out?(relation_filter) do
      []
    else
      reverse_termination_facts_for_gateway(key, scopes, min_corr)
    end
  end

  defp reverse_termination_facts(_key, _scopes, _min_corr, _relation_filter), do: []

  defp terminates_for_filtered_out?(relations) when is_list(relations),
    do: "terminates_for" not in relations

  defp terminates_for_filtered_out?(_), do: false

  defp reverse_termination_facts_for_gateway(key, scopes, min_corr) do
    edge_class = Freshness.sql_class_case("e.type")
    frontier_class = Freshness.sql_class_case("ef.type")

    %{rows: rows} =
      Repo.query!(
        """
        WITH freshness_frontier AS (
          SELECT #{frontier_class} AS freshness_class,
                 max(ef.last_seen) AS last_seen
            FROM edge ef
           GROUP BY 1
        )
        SELECT 'terminates_for'::text, s.key, s.net_address_class, e.seen_count,
               e.reliability::float8,
               extract(epoch FROM (ff.last_seen - e.last_seen))::float8 AS age_sec
          FROM edge e
          JOIN freshness_frontier ff ON ff.freshness_class = #{edge_class}
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE d.key = $1
           AND e.type = 'terminates_at'
           AND e.reward >= 0
           AND e.visibility_scope = ANY($2)
           AND s.scope = ANY($2)
           AND d.scope = ANY($2)
           AND e.seen_count >= $3
         ORDER BY e.reliability DESC, s.key
         LIMIT 30
        """,
        [key, scopes, min_corr]
      )

    Enum.map(rows, &fact_from_row/1)
  end

  defp fact_from_row([type, dkey, address_class, seen, rel, age]) do
    age = age || 0.0

    %{
      relation: type,
      object: strip_ns(dkey),
      object_kind: decode_key(dkey).kind,
      address_class: address_class,
      cardinality: cardinality(type),
      corroboration: seen,
      effective_reliability: Freshness.effective_reliability(rel || 0.0, age, type),
      fresh?: Freshness.fresh?(age, type)
    }
  end

  @spec query_terms(String.t()) :: [String.t()]
  defp query_terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stopwords))
    |> Enum.uniq()
  end

  defp query_vec(opts) do
    case Keyword.get(opts, :query_vec) do
      [_ | _] = vec -> Pgvector.new(vec)
      _ -> nil
    end
  end

  defp network_literals(query) do
    ipv4 = ~r/\b(?:\d{1,3}\.){3}\d{1,3}(?:\/\d{1,2})?\b/
    ipv6 = ~r/\b[0-9a-f]{0,4}:[0-9a-f:]+(?:\/\d{1,3})?\b/i

    (Regex.scan(ipv4, query) ++ Regex.scan(ipv6, query))
    |> List.flatten()
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
