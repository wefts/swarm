defmodule Swarm.Enrichment.TopologyJoin do
  @moduledoc """
  Deterministic network-layer joins and conservative identity bridges.

  This pass derives only from already-present graph evidence. It does not parse
  prose, does not call a model, and does not invent relation vocabulary:

  * `net:site:* contains net:cluster:*` when a cluster host address falls inside a
    site range.
  * `net:cluster:* routes_via net:gateway:*` when a cluster host address falls
    inside a range carried by a gateway.
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

    joins = topology_join_candidates(rows)
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
      SELECT e.id, s.key, e.type, d.key, e.reliability::float8, e.seen_count,
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
         )
       GROUP BY e.id, s.key, e.type, d.key, e.reliability, e.seen_count
       ORDER BY s.key, e.type, d.key
      """,
      [gateway, scopes]
    ).rows
    |> Enum.map(fn [id, src, rel, dst, reliability, seen, provenances, origins] ->
      %{
        edge_id: id,
        src: src,
        relation: rel,
        dst: dst,
        reliability: reliability,
        seen_count: seen,
        evidence: Enum.sort(provenances),
        origins: Enum.sort(origins)
      }
    end)
  end

  defp topology_join_candidates(rows) do
    cluster_hosts =
      rows
      |> Enum.filter(
        &(&1.type == "contains" and kind(&1.src_key) == "cluster" and kind(&1.dst_key) == "host")
      )
      |> Enum.group_by(& &1.dst_id)

    host_addresses =
      rows
      |> Enum.filter(
        &(&1.type in ["has_address", "has_outbound_ip_address"] and kind(&1.src_key) == "host")
      )
      |> Enum.flat_map(fn row ->
        with {:ok, ip} <- parse_ip(name(row.dst_key)),
             cluster_edges when cluster_edges != [] <- Map.get(cluster_hosts, row.src_id, []) do
          Enum.map(cluster_edges, fn cluster_edge ->
            %{
              host_key: row.src_key,
              cluster_id: cluster_edge.src_id,
              cluster_key: cluster_edge.src_key,
              ip: ip,
              evidence: [row, cluster_edge]
            }
          end)
        else
          _ -> []
        end
      end)

    site_ranges =
      rows
      |> Enum.filter(fn row ->
        row.type in ["has_address", "contains"] and kind(row.src_key) == "site" and
          kind(row.dst_key) in ["address", "subnet"]
      end)
      |> Enum.flat_map(&range_row/1)

    gateway_ranges =
      direct_gateway_ranges(rows) ++ tunnel_gateway_ranges(rows)

    site_joins =
      for host <- host_addresses,
          range <- site_ranges,
          in_range?(host.ip, range.range) do
        candidate(
          range.src_id,
          host.cluster_id,
          "contains",
          range.scope,
          range.src_key,
          host.cluster_key,
          range.evidence ++ host.evidence
        )
      end

    gateway_joins =
      for host <- host_addresses,
          range <- gateway_ranges,
          in_range?(host.ip, range.range) do
        candidate(
          host.cluster_id,
          range.src_id,
          "routes_via",
          range.scope,
          host.cluster_key,
          range.src_key,
          range.evidence ++ host.evidence
        )
      end

    (site_joins ++ gateway_joins)
    |> Enum.uniq_by(&{&1.src_id, &1.relation, &1.dst_id, &1.scope})
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
        ~w(contains has_address has_outbound_ip_address carries routes_via egresses_via terminates_at alias_of)
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

  defp range_row(row) do
    case parse_range(name(row.dst_key)) do
      {:ok, range} ->
        [
          %{
            src_id: row.src_id,
            src_key: row.src_key,
            scope: row.scope,
            range: range,
            evidence: [row]
          }
        ]

      :error ->
        []
    end
  end

  defp direct_gateway_ranges(rows) do
    rows
    |> Enum.filter(fn row ->
      kind(row.src_key) == "gateway" and
        ((row.type == "carries" and kind(row.dst_key) == "subnet") or
           (row.type == "has_address" and kind(row.dst_key) in ["address", "subnet"]))
    end)
    |> Enum.flat_map(&range_row/1)
  end

  defp tunnel_gateway_ranges(rows) do
    tunnel_ranges =
      rows
      |> Enum.filter(
        &(&1.type == "carries" and kind(&1.src_key) == "tunnel" and kind(&1.dst_key) == "subnet")
      )
      |> Enum.flat_map(fn row ->
        case parse_range(name(row.dst_key)) do
          {:ok, range} -> [%{tunnel_id: row.src_id, range: range, evidence: [row]}]
          :error -> []
        end
      end)

    tunnel_gateways =
      rows
      |> Enum.filter(
        &(&1.type == "terminates_at" and kind(&1.src_key) == "tunnel" and
            kind(&1.dst_key) == "gateway")
      )
      |> Enum.group_by(& &1.src_id)

    Enum.flat_map(tunnel_ranges, fn tunnel_range ->
      tunnel_gateways
      |> Map.get(tunnel_range.tunnel_id, [])
      |> Enum.map(fn gateway_edge ->
        %{
          src_id: gateway_edge.dst_id,
          src_key: gateway_edge.dst_key,
          scope: gateway_edge.scope,
          range: tunnel_range.range,
          evidence: tunnel_range.evidence ++ [gateway_edge]
        }
      end)
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

  defp parse_range(value) do
    case String.split(value, "/", parts: 2) do
      [ip, prefix] ->
        with {:ok, addr} <- parse_ip(ip),
             {prefix_int, ""} <- Integer.parse(prefix),
             true <- prefix_int >= 0 and prefix_int <= 32 do
          {:ok, {addr, prefix_int}}
        else
          _ -> :error
        end

      [ip] ->
        with {:ok, addr} <- parse_ip(ip), do: {:ok, {addr, 32}}
    end
  end

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_ipv4_address(String.to_charlist(value)) do
      {:ok, tuple} -> {:ok, ipv4_to_int(tuple)}
      _ -> :error
    end
  end

  defp ipv4_to_int({a, b, c, d}), do: a * 16_777_216 + b * 65_536 + c * 256 + d

  defp in_range?(ip, {network, prefix}) do
    mask = Bitwise.bsl(0xFFFFFFFF, 32 - prefix) |> Bitwise.band(0xFFFFFFFF)
    Bitwise.band(ip, mask) == Bitwise.band(network, mask)
  end
end
