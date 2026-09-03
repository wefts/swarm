defmodule Swarm.Enrichment.TopologyJoin do
  @moduledoc """
  Deterministic network-layer joins and conservative identity bridges.

  This pass derives only from already-present graph evidence. It does not parse
  prose, does not call a model, and does not invent relation vocabulary:

  * `net:site:* contains net:cluster:*` when a cluster host address falls inside a
    site range.
  * `net:host:* routes_via net:gateway:*` when that host's address falls inside
    a range carried by a gateway.
  * `alias_of` bridges for exact IP/FQDN cross-namespace duplicate keys.
  * `net:cluster:<platform> contains net:cluster:<platform>-<env>` for governed
    environment variants, while recording do-not-merge blockers.

  All writes use stable derived provenance. A derived join is absent unless the
  supporting source edges are visible in the requested scopes.
  """

  alias Swarm.Graph.Store
  alias Swarm.Repo

  @entity_type "entity"
  @join_origin "enrich:topology_join"
  @identity_origin "enrich:topology_identity"
  @env_suffixes ~w(prod dev pp test tools old)
  @fqdn_re ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/i

  @type summary :: %{
          joins: non_neg_integer(),
          bridges: non_neg_integer(),
          variants: non_neg_integer(),
          blocked: non_neg_integer(),
          dry_run?: boolean()
        }

  @doc """
  Derive topology joins and identity bridges visible to `scopes`.

  Options:

  * `:apply` - write derived edges when true; otherwise return counts only.
  """
  @spec derive([String.t()], keyword()) :: summary()
  def derive(scopes, opts \\ []) when is_list(scopes) do
    apply? = Keyword.get(opts, :apply, false)
    rows = relation_rows(scopes)

    joins = topology_join_candidates(scopes, rows)
    bridges = exact_identity_bridge_candidates(scopes) ++ cluster_name_bridge_candidates(scopes)
    variants = environment_variant_candidates(scopes)

    join_writes = write_candidates(joins, apply?)
    bridge_writes = write_candidates(bridges, apply?)
    variant_writes = write_variant_candidates(variants, apply?)

    %{
      joins: length(join_writes),
      bridges: length(bridge_writes),
      variants: length(variant_writes),
      blocked: Enum.count(bridges ++ variants, & &1.blocked?),
      dry_run?: not apply?
    }
  end

  @doc """
  Render confirmed edges around a gateway with the supporting upstream evidence.
  """
  @spec gateway_tree(String.t(), [String.t()]) :: [map()]
  def gateway_tree(gateway_key, scopes) when is_binary(gateway_key) and is_list(scopes) do
    gateway = normalize_gateway_key(gateway_key)

    Repo.query!(
      """
      WITH routed_hosts AS (
        SELECT DISTINCT e.src AS host_id
          FROM edge e
          JOIN node g ON g.id = e.dst
         WHERE g.key = $1
           AND e.type IN ('routes_via', 'egresses_via')
           AND e.reward >= 0
           AND e.visibility_scope = ANY($2)
      )
      SELECT e.id, s.id, s.key, e.type, d.id, d.key, e.reliability::float8, e.seen_count,
             COALESCE(array_agg(DISTINCT ep.provenance) FILTER (WHERE ep.provenance IS NOT NULL), '{}') AS provenances,
             COALESCE(array_agg(DISTINCT ep.origin) FILTER (WHERE ep.origin IS NOT NULL), '{}') AS origins
        FROM edge e
        JOIN node s ON s.id = e.src
        JOIN node d ON d.id = e.dst
        LEFT JOIN edge_provenance ep ON ep.edge_id = e.id
       WHERE e.reward >= 0
         AND e.visibility_scope = ANY($2)
         AND s.scope = ANY($2)
         AND d.scope = ANY($2)
         AND (
           (s.key = $1 AND e.type IN ('carries', 'contains', 'routes_via', 'egresses_via', 'terminates_at'))
           OR (d.key = $1 AND e.type IN ('routes_via', 'egresses_via', 'terminates_at'))
           OR (
             e.type = 'contains'
             AND s.key LIKE 'net:cluster:%'
             AND d.key LIKE 'net:host:%'
             AND d.id IN (SELECT host_id FROM routed_hosts)
           )
         )
       GROUP BY e.id, s.id, s.key, e.type, d.id, d.key, e.reliability, e.seen_count
       ORDER BY s.key, e.type, d.key
      """,
      [gateway, scopes]
    ).rows
    |> then(fn rows ->
      context_by_host = cluster_context_by_host(gateway, scopes)

      Enum.map(rows, fn [
                          id,
                          src_id,
                          src,
                          rel,
                          dst_id,
                          dst,
                          reliability,
                          seen,
                          provenances,
                          origins
                        ] ->
        cluster_context =
          cond do
            kind(src) == "host" -> Map.get(context_by_host, src_id, [])
            kind(dst) == "host" -> Map.get(context_by_host, dst_id, [])
            true -> []
          end

        %{
          edge_id: id,
          src: src,
          relation: rel,
          dst: dst,
          reliability: reliability,
          seen_count: seen,
          evidence: Enum.sort(provenances),
          origins: Enum.sort(origins),
          cluster_context: cluster_context
        }
      end)
    end)
  end

  defp cluster_context_by_host(gateway, scopes) do
    Repo.query!(
      """
      WITH routed_hosts AS (
        SELECT DISTINCT e.src AS host_id
          FROM edge e
          JOIN node g ON g.id = e.dst
         WHERE g.key = $1
           AND e.type IN ('routes_via', 'egresses_via')
           AND e.reward >= 0
           AND e.visibility_scope = ANY($2)
      ),
      cluster_members AS (
        SELECT e.src AS cluster_id, c.key AS cluster_key, e.dst AS host_id
          FROM edge e
          JOIN node c ON c.id = e.src
          JOIN node h ON h.id = e.dst
         WHERE e.type = 'contains'
           AND e.reward >= 0
           AND e.visibility_scope = ANY($2)
           AND c.scope = ANY($2)
           AND h.scope = ANY($2)
           AND c.key LIKE 'net:cluster:%'
           AND h.key LIKE 'net:host:%'
      ),
      cluster_counts AS (
        SELECT cluster_id, count(*) AS member_count
          FROM cluster_members
         GROUP BY cluster_id
      ),
      routed_counts AS (
        SELECT cm.cluster_id, count(*) AS routed_member_count
          FROM cluster_members cm
          JOIN routed_hosts rh ON rh.host_id = cm.host_id
         GROUP BY cm.cluster_id
      )
      SELECT cm.host_id,
             cm.cluster_key,
             cc.member_count,
             rc.routed_member_count
        FROM cluster_members cm
        JOIN routed_hosts routed ON routed.host_id = cm.host_id
        JOIN cluster_counts cc ON cc.cluster_id = cm.cluster_id
        JOIN routed_counts rc ON rc.cluster_id = cm.cluster_id
       ORDER BY cm.host_id, cm.cluster_key
      """,
      [gateway, scopes]
    ).rows
    |> Enum.group_by(fn [host_id, _cluster_key, _member_count, _routed_member_count] ->
      host_id
    end)
    |> Map.new(fn {host_id, rows} ->
      contexts =
        Enum.map(rows, fn [_host_id, cluster_key, member_count, routed_member_count] ->
          %{
            cluster: cluster_key,
            routed_members: routed_member_count,
            total_members: member_count
          }
        end)

      {host_id, contexts}
    end)
  end

  defp topology_join_candidates(scopes, rows) do
    row_by_id = Map.new(rows, &{&1.id, &1})

    scopes
    |> topology_join_candidate_rows()
    |> Enum.map(fn [src_id, src_key, relation, dst_id, dst_key, scope, evidence_ids] ->
      evidence =
        evidence_ids
        |> Enum.map(&Map.fetch!(row_by_id, &1))
        |> Enum.uniq_by(& &1.id)

      candidate(src_id, dst_id, relation, scope, src_key, dst_key, evidence)
    end)
    |> Enum.uniq_by(&{&1.src_id, &1.relation, &1.dst_id, &1.scope})
  end

  defp topology_join_candidate_rows(scopes) do
    Repo.query!(
      """
      WITH host_addresses AS (
        SELECT e.id AS address_edge_id, h.id AS host_id, h.key AS host_key,
               h.scope AS host_scope, a.net_addr AS addr, e.visibility_scope AS scope
          FROM edge e
          JOIN node h ON h.id = e.src
          JOIN node a ON a.id = e.dst
         WHERE e.reward >= 0
           AND e.type IN ('has_address', 'has_private_address', 'has_public_address', 'has_outbound_ip_address')
           AND h.key LIKE 'net:host:%'
           AND a.net_addr IS NOT NULL
           AND e.visibility_scope = ANY($1)
           AND h.scope = ANY($1)
           AND a.scope = ANY($1)
      ),
      cluster_hosts AS (
        SELECT e.id AS cluster_edge_id, c.id AS cluster_id, c.key AS cluster_key,
               c.scope AS cluster_scope, h.id AS host_id
          FROM edge e
          JOIN node c ON c.id = e.src
          JOIN node h ON h.id = e.dst
         WHERE e.reward >= 0
           AND e.type = 'contains'
           AND c.key LIKE 'net:cluster:%'
           AND h.key LIKE 'net:host:%'
           AND e.visibility_scope = ANY($1)
           AND c.scope = ANY($1)
           AND h.scope = ANY($1)
      ),
      site_ranges AS (
        SELECT e.id AS range_edge_id, s.id AS site_id, s.key AS site_key,
               s.scope AS site_scope, r.net_range AS range, e.visibility_scope AS scope
          FROM edge e
          JOIN node s ON s.id = e.src
          JOIN node r ON r.id = e.dst
         WHERE e.reward >= 0
           AND e.type IN ('has_address', 'has_private_address', 'has_public_address', 'contains')
           AND s.key LIKE 'net:site:%'
           AND r.net_range IS NOT NULL
           AND e.visibility_scope = ANY($1)
           AND s.scope = ANY($1)
           AND r.scope = ANY($1)
      ),
      direct_gateway_ranges AS (
        SELECT e.id AS range_edge_id, g.id AS gateway_id, g.key AS gateway_key,
               g.scope AS gateway_scope, r.net_range AS range, e.visibility_scope AS scope
          FROM edge e
          JOIN node g ON g.id = e.src
          JOIN node r ON r.id = e.dst
         WHERE e.reward >= 0
           AND (
             (e.type = 'carries' AND r.key LIKE 'net:subnet:%')
             OR (e.type IN ('has_address', 'has_private_address', 'has_public_address') AND r.key LIKE 'net:address:%')
           )
           AND g.key LIKE 'net:gateway:%'
           AND r.net_range IS NOT NULL
           AND e.visibility_scope = ANY($1)
           AND g.scope = ANY($1)
           AND r.scope = ANY($1)
      ),
      tunnel_ranges AS (
        SELECT e.id AS range_edge_id, t.id AS tunnel_id, r.net_range AS range
          FROM edge e
          JOIN node t ON t.id = e.src
          JOIN node r ON r.id = e.dst
         WHERE e.reward >= 0
           AND e.type = 'carries'
           AND t.key LIKE 'net:tunnel:%'
           AND r.key LIKE 'net:subnet:%'
           AND r.net_range IS NOT NULL
           AND e.visibility_scope = ANY($1)
           AND t.scope = ANY($1)
           AND r.scope = ANY($1)
      ),
      tunnel_gateway_ranges AS (
        SELECT te.id AS terminate_edge_id, tr.range_edge_id, g.id AS gateway_id,
               g.key AS gateway_key, g.scope AS gateway_scope, tr.range, te.visibility_scope AS scope
          FROM tunnel_ranges tr
          JOIN edge te ON te.src = tr.tunnel_id
          JOIN node g ON g.id = te.dst
         WHERE te.reward >= 0
           AND te.type = 'terminates_at'
           AND g.key LIKE 'net:gateway:%'
           AND te.visibility_scope = ANY($1)
           AND g.scope = ANY($1)
      ),
      gateway_ranges AS (
        SELECT gateway_id, gateway_key, gateway_scope, range, scope, ARRAY[range_edge_id]::bigint[] AS evidence_ids
          FROM direct_gateway_ranges
        UNION ALL
        SELECT gateway_id, gateway_key, gateway_scope, range, scope,
               ARRAY[range_edge_id, terminate_edge_id]::bigint[] AS evidence_ids
          FROM tunnel_gateway_ranges
      ),
      site_joins AS (
        SELECT sr.site_id AS src_id, sr.site_key AS src_key, 'contains'::text AS relation,
               ch.cluster_id AS dst_id, ch.cluster_key AS dst_key,
               CASE
                 WHEN sr.site_scope = ch.cluster_scope THEN sr.site_scope
                 WHEN sr.site_scope = 'private' OR ch.cluster_scope = 'private' THEN 'private'
                 WHEN sr.site_scope = 'public' THEN ch.cluster_scope
                 WHEN ch.cluster_scope = 'public' THEN sr.site_scope
                 ELSE 'private'
               END AS scope,
               ARRAY[sr.range_edge_id, ha.address_edge_id, ch.cluster_edge_id]::bigint[] AS evidence_ids
          FROM host_addresses ha
          JOIN cluster_hosts ch ON ch.host_id = ha.host_id
          JOIN site_ranges sr ON ha.addr <<= sr.range
      ),
      gateway_joins AS (
        SELECT ha.host_id AS src_id, ha.host_key AS src_key, 'routes_via'::text AS relation,
               gr.gateway_id AS dst_id, gr.gateway_key AS dst_key,
               CASE
                 WHEN ha.host_scope = gr.gateway_scope THEN ha.host_scope
                 WHEN ha.host_scope = 'private' OR gr.gateway_scope = 'private' THEN 'private'
                 WHEN ha.host_scope = 'public' THEN gr.gateway_scope
                 WHEN gr.gateway_scope = 'public' THEN ha.host_scope
                 ELSE 'private'
               END AS scope,
               array_append(gr.evidence_ids, ha.address_edge_id) AS evidence_ids
          FROM host_addresses ha
          -- Evidence may come from different source scopes. Requiring equal
          -- visibility scopes hides valid deterministic joins when the host
          -- inventory and gateway ranges were ingested from separate sources;
          -- the WHERE clauses above already require every supporting edge to
          -- be visible to the requested scopes. The derived edge uses the
          -- endpoint-scope GLB, so cross-source joins clamp to private.
          JOIN gateway_ranges gr ON ha.addr <<= gr.range
      )
      SELECT src_id, src_key, relation, dst_id, dst_key, scope, evidence_ids FROM site_joins
      UNION ALL
      SELECT src_id, src_key, relation, dst_id, dst_key, scope, evidence_ids FROM gateway_joins
      """,
      [scopes]
    ).rows
  end

  defp exact_identity_bridge_candidates(scopes) do
    rows =
      Repo.query!(
        """
        SELECT net.id, net.key, plain.id, plain.key, net.scope
          FROM node net
          JOIN node plain ON plain.type = net.type
                         AND plain.scope = net.scope
                         AND lower(plain.key) = lower(split_part(net.key, ':', 3))
         WHERE net.type = 'entity'
           AND net.scope = ANY($1)
           AND net.key LIKE 'net:%:%'
           AND plain.key NOT LIKE 'net:%'
        """,
        [scopes]
      ).rows

    rows
    |> Enum.filter(fn [_net_id, net_key, _plain_id, plain_key, _scope] ->
      (kind(net_key) == "address" and match?({:ok, _}, parse_ip(plain_key))) or
        (kind(net_key) == "host" and Regex.match?(@fqdn_re, plain_key))
    end)
    |> Enum.flat_map(fn [net_id, net_key, plain_id, plain_key, scope] ->
      bridge_pair(net_id, net_key, plain_id, plain_key, scope)
    end)
  end

  defp environment_variant_candidates(scopes) do
    rows =
      Repo.query!(
        """
        SELECT base.id, base.key, variant.id, variant.key, base.scope
          FROM node base
          JOIN node variant ON variant.type = base.type
                           AND variant.scope = base.scope
                           AND variant.key LIKE base.key || '-%'
         WHERE base.type = 'entity'
           AND base.scope = ANY($1)
           AND base.key LIKE 'net:cluster:%'
        """,
        [scopes]
      ).rows

    rows
    |> Enum.filter(fn [_base_id, base_key, _variant_id, variant_key, _scope] ->
      suffix = variant_suffix(base_key, variant_key)

      base_platform_key?(base_key) and
        (suffix in @env_suffixes or String.ends_with?(variant_key, "-prod-old"))
    end)
    |> Enum.map(fn [base_id, base_key, variant_id, variant_key, scope] ->
      blocked? = Store.merge_blocked?(@entity_type, base_key, variant_key)

      %{
        src_id: base_id,
        dst_id: variant_id,
        relation: "contains",
        scope: scope,
        src_key: base_key,
        dst_key: variant_key,
        evidence: [],
        provenance: "topology_identity:variant:#{base_key}->#{variant_key}",
        origin: @identity_origin,
        lineage: "topology_identity:variant",
        reliability: 0.65,
        blocked?: blocked?
      }
    end)
  end

  defp cluster_name_bridge_candidates(scopes) do
    rows =
      Repo.query!(
        """
        SELECT base.id, base.key, alias.id, alias.key, base.scope
          FROM node base
          JOIN node alias ON alias.type = base.type
                         AND alias.scope = base.scope
                         AND alias.key = base.key || ' cluster'
         WHERE base.type = 'entity'
           AND base.scope = ANY($1)
           AND base.key LIKE 'net:cluster:%'
        """,
        [scopes]
      ).rows

    rows
    |> Enum.reject(fn [_base_id, base_key, _alias_id, _alias_key, _scope] ->
      not base_platform_key?(base_key)
    end)
    |> Enum.flat_map(fn [base_id, base_key, alias_id, alias_key, scope] ->
      bridge_pair(base_id, base_key, alias_id, alias_key, scope)
    end)
  end

  defp bridge_pair(net_id, net_key, plain_id, plain_key, scope) do
    if Store.merge_blocked?(@entity_type, net_key, plain_key) do
      []
    else
      for {src_id, src_key, dst_id, dst_key} <- [
            {net_id, net_key, plain_id, plain_key},
            {plain_id, plain_key, net_id, net_key}
          ] do
        %{
          src_id: src_id,
          dst_id: dst_id,
          relation: "alias_of",
          scope: scope,
          src_key: src_key,
          dst_key: dst_key,
          evidence: [],
          provenance: "topology_identity:exact:#{src_key}->#{dst_key}",
          origin: @identity_origin,
          lineage: "topology_identity:exact",
          reliability: 0.9,
          blocked?: false
        }
      end
    end
  end

  defp write_candidates(candidates, false), do: candidates

  defp write_candidates(candidates, true) do
    Enum.flat_map(candidates, fn c ->
      case Store.add_edge(c.src_id, c.dst_id, c.relation, provenance(c),
             scope: c.scope,
             origin: c.origin || @join_origin,
             lineage: c.lineage || lineage(c),
             reliability: c.reliability || reliability(c.evidence),
             evidence_kind: "derived"
           ) do
        {:ok, _edge} -> [c]
        {:error, _} -> []
      end
    end)
  end

  defp write_variant_candidates(candidates, false), do: candidates

  defp write_variant_candidates(candidates, true) do
    Enum.flat_map(candidates, fn c ->
      Store.block_merge(@entity_type, c.src_key, c.dst_key, "environment variant")

      case Store.add_edge(c.src_id, c.dst_id, c.relation, c.provenance,
             scope: c.scope,
             origin: c.origin,
             lineage: c.lineage,
             reliability: c.reliability,
             evidence_kind: "derived"
           ) do
        {:ok, _edge} -> [c]
        {:error, _} -> []
      end
    end)
  end

  defp relation_rows(scopes) do
    Repo.query!(
      """
      SELECT e.id, s.id, s.key, e.type, d.id, d.key, e.visibility_scope,
             e.reliability::float8, e.evidence_kind,
             COALESCE(array_agg(DISTINCT coalesce(ep.lineage, ep.origin, ep.provenance))
                      FILTER (WHERE ep.provenance IS NOT NULL), '{}') AS lineages,
             COALESCE(array_agg(DISTINCT coalesce(ep.origin, ep.provenance))
                      FILTER (WHERE ep.provenance IS NOT NULL), '{}') AS origins
        FROM edge e
        JOIN node s ON s.id = e.src
        JOIN node d ON d.id = e.dst
        LEFT JOIN edge_provenance ep ON ep.edge_id = e.id
       WHERE e.reward >= 0
         AND e.visibility_scope = ANY($1)
         AND s.scope = ANY($1)
         AND d.scope = ANY($1)
         AND e.type = ANY($2)
       GROUP BY e.id, s.id, s.key, e.type, d.id, d.key, e.visibility_scope,
                e.reliability, e.evidence_kind
      """,
      [
        scopes,
        ~w(contains has_address has_private_address has_public_address has_outbound_ip_address carries routes_via egresses_via terminates_at alias_of)
      ]
    ).rows
    |> Enum.map(fn [
                     id,
                     src_id,
                     src_key,
                     type,
                     dst_id,
                     dst_key,
                     scope,
                     reliability,
                     evidence_kind,
                     lineages,
                     origins
                   ] ->
      %{
        id: id,
        src_id: src_id,
        src_key: src_key,
        type: type,
        dst_id: dst_id,
        dst_key: dst_key,
        scope: scope,
        reliability: reliability,
        evidence_kind: evidence_kind,
        lineages: lineages,
        origins: origins
      }
    end)
  end

  defp candidate(src_id, dst_id, relation, scope, src_key, dst_key, evidence) do
    %{
      src_id: src_id,
      dst_id: dst_id,
      relation: relation,
      scope: scope,
      src_key: src_key,
      dst_key: dst_key,
      evidence: Enum.uniq_by(evidence, & &1.id),
      provenance: nil,
      origin: nil,
      lineage: nil,
      reliability: nil,
      blocked?: false
    }
  end

  defp provenance(%{provenance: p}) when is_binary(p), do: p

  defp provenance(c) do
    ids = c.evidence |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join(",")
    "topology_join:#{c.src_key}:#{c.relation}:#{c.dst_key}:#{ids}"
  end

  defp lineage(c) do
    c.evidence
    |> Enum.flat_map(& &1.lineages)
    |> Enum.sort()
    |> then(fn
      [] -> "topology_join:unknown"
      lineages -> "topology_join:" <> Enum.join(lineages, "+")
    end)
  end

  defp reliability(evidence) do
    if Enum.any?(evidence, &iac?/1) do
      0.82
    else
      evidence
      |> Enum.map(&(&1.reliability || 0.0))
      |> Enum.max(fn -> 0.55 end)
      |> min(0.72)
    end
  end

  defp iac?(row) do
    Enum.any?(row.origins, &String.starts_with?(&1 || "", "iac:")) or
      row.evidence_kind == "observation"
  end

  defp kind("net:" <> rest), do: rest |> String.split(":", parts: 2) |> hd()
  defp kind(_), do: nil

  defp name("net:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [_kind, name] -> name
      _ -> rest
    end
  end

  defp name(key), do: key

  defp normalize_gateway_key("net:gateway:" <> _ = key), do: key
  defp normalize_gateway_key(key), do: "net:gateway:" <> key

  defp variant_suffix(base_key, variant_key) do
    variant_key
    |> String.replace_prefix(base_key <> "-", "")
    |> String.split("-", parts: 2)
    |> hd()
  end

  defp base_platform_key?(key) do
    name = name(key)

    not Enum.any?(@env_suffixes, fn suffix ->
      String.ends_with?(name, "-" <> suffix) or String.contains?(name, "-" <> suffix <> "-")
    end)
  end

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  end
end
