defmodule Swarm.Graph.Neighborhood do
  @moduledoc """
  Bounded, scope-enforced neighborhood projection (swarm ADR-15) — the read-only
  "connections" surface for the dashboard.

  Reuses `Graph.Traverse.walk/3` (which already prunes on BOTH `node.scope` and
  `edge.visibility_scope`, ADR-5, and excludes refuted `reward < 0` traces, T12)
  for the reachable in-scope node set, then hydrates node identity and projects the
  typed edges *among the returned set*. Bounded by contract: `depth ≤ 2`, `≤ 50`
  nodes, an optional relation-type filter — never the full hairball.

  No-leak (the kernel is the scope authority): the center must itself be visible to
  the request scopes or the result is `:not_found` (existence is never revealed); a
  hydrated node is re-checked in-scope; an edge appears only when its **own**
  `visibility_scope` is within the request scopes *and* both endpoints are in the
  returned set (an edge can be private between two visible nodes — endpoint
  visibility alone is insufficient).

  Consistency: like `Core.status`/`search`, the projection issues independent
  read-committed queries rather than one snapshot — node `scope` is effectively
  immutable post-ingest (a rescope is a rare admin op), so a torn read across a
  concurrent rescope is transient and benign for this read-only surface.
  """

  alias Swarm.Graph.Traverse
  alias Swarm.Repo

  @max_depth 2
  @max_nodes 50
  @default_depth 1
  @default_nodes 50

  @type node_view :: %{
          id: integer(),
          type: String.t(),
          key: String.t(),
          scope: String.t(),
          confidence: float(),
          depth: integer()
        }
  @type edge_view :: %{
          src_id: integer(),
          dst_id: integer(),
          relation: String.t(),
          reliability: float()
        }
  @type result :: %{
          center_id: integer(),
          nodes: [node_view()],
          edges: [edge_view()],
          truncated: boolean()
        }

  @doc """
  Project the neighborhood around `center_id`. `opts`: `:scopes` (allowed
  visibility scopes, default-deny — empty ⇒ `:not_found`), `:depth` (clamped to
  `[1,2]`, `0`/absent ⇒ #{@default_depth}), `:node_limit` (clamped to `[1,50]`,
  `0`/absent ⇒ #{@default_nodes}), `:relation_types` (edge-type filter; empty ⇒ all).

  Returns `{:ok, result()}` or `{:error, :not_found}` when the center is not
  visible to the scopes (or does not exist).
  """
  @spec query(integer(), keyword()) :: {:ok, result()} | {:error, :not_found}
  def query(center_id, opts \\ []) when is_integer(center_id) do
    scopes = Keyword.get(opts, :scopes, [])
    depth = clamp(Keyword.get(opts, :depth, @default_depth), 1, @max_depth, @default_depth)

    node_limit =
      clamp(Keyword.get(opts, :node_limit, @default_nodes), 1, @max_nodes, @default_nodes)

    relation_types = Keyword.get(opts, :relation_types, [])

    if center_visible?(center_id, scopes) do
      %{hits: hits, truncated: truncated} = Traverse.walk(center_id, depth, scopes: scopes)
      # Hydrate (which RE-CHECKS scope) BEFORE capping, so the cap and `truncated`
      # reflect only scope-confirmed nodes: an out-of-scope hit can never consume
      # the cap or flip `truncated` even if `walk` were to regress (council:
      # defense-in-depth, not just the trusted ADR-5 traversal filter).
      visible = hydrate(hits, scopes)
      nodes = Enum.take(visible, node_limit)
      capped? = length(visible) > node_limit
      member_ids = [center_id | Enum.map(nodes, & &1.id)]
      edges = project_edges(member_ids, scopes, relation_types)

      {:ok, %{center_id: center_id, nodes: nodes, edges: edges, truncated: truncated or capped?}}
    else
      {:error, :not_found}
    end
  end

  # 0/absent ⇒ default; otherwise clamp into [lo, hi]. The wire sends uint32 where
  # 0 means "unset" (proto3 has no field presence for scalars here).
  @spec clamp(integer(), pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  defp clamp(v, _lo, _hi, default) when not is_integer(v) or v <= 0, do: default
  defp clamp(v, lo, _hi, _default) when v < lo, do: lo
  defp clamp(v, _lo, hi, _default) when v > hi, do: hi
  defp clamp(v, _lo, _hi, _default), do: v

  @spec center_visible?(integer(), [String.t()]) :: boolean()
  defp center_visible?(_id, []), do: false

  defp center_visible?(id, scopes) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM node WHERE id = $1 AND scope = ANY($2::text[]) LIMIT 1",
        [id, scopes]
      )

    rows != []
  end

  # Hydrate node identity for the kept hits, re-checking scope (defense in depth),
  # and re-attach the walk's confidence/depth. Deterministic order: confidence
  # desc, then id asc.
  @spec hydrate([Traverse.hit()], [String.t()]) :: [node_view()]
  defp hydrate([], _scopes), do: []

  defp hydrate(hits, scopes) do
    ids = Enum.map(hits, & &1.id)

    %{rows: rows} =
      Repo.query!(
        "SELECT id, type, key, scope FROM node WHERE id = ANY($1) AND scope = ANY($2::text[])",
        [ids, scopes]
      )

    meta =
      Map.new(rows, fn [id, type, key, scope] -> {id, %{type: type, key: key, scope: scope}} end)

    hits
    |> Enum.flat_map(fn h ->
      case Map.get(meta, h.id) do
        nil -> []
        m -> [Map.merge(m, %{id: h.id, confidence: h.confidence, depth: h.depth})]
      end
    end)
    |> Enum.sort_by(&{-&1.confidence, &1.id})
  end

  # Typed edges among the member set (center + returned nodes). Scope-enforced on
  # the edge's OWN visibility_scope, refuted excluded, optional relation filter.
  @spec project_edges([integer()], [String.t()], [String.t()]) :: [edge_view()]
  defp project_edges(member_ids, scopes, relation_types) do
    {sql, params} = edge_sql(member_ids, scopes, relation_types)
    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [src, dst, rel, reliability] ->
      %{src_id: src, dst_id: dst, relation: rel, reliability: reliability}
    end)
  end

  defp edge_sql(ids, scopes, []) do
    {"""
       SELECT e.src, e.dst, e.type, e.reliability
         FROM edge e
        WHERE e.src = ANY($1) AND e.dst = ANY($1)
          AND e.visibility_scope = ANY($2::text[]) AND e.reward >= 0
        ORDER BY e.src, e.dst, e.type, e.visibility_scope
     """, [ids, scopes]}
  end

  defp edge_sql(ids, scopes, relation_types) do
    {"""
       SELECT e.src, e.dst, e.type, e.reliability
         FROM edge e
        WHERE e.src = ANY($1) AND e.dst = ANY($1)
          AND e.visibility_scope = ANY($2::text[]) AND e.reward >= 0
          AND e.type = ANY($3::text[])
        ORDER BY e.src, e.dst, e.type, e.visibility_scope
     """, [ids, scopes, relation_types]}
  end
end
