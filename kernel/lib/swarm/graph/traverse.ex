defmodule Swarm.Graph.Traverse do
  @moduledoc """
  Bounded graph traversal — the primitive the gate later uses as "thinking".

  Confidence is computed by **node-bounded relaxation** (swarm ADR-3), not per-path
  enumeration. The old recursive CTE materialised one row per *path* (`fanout^depth`)
  only to collapse it to `max(conf)` per node — provably wasteful, and it could not
  enumerate past ~72k path-rows on dense graphs. This is a level-synchronous bounded
  Bellman-Ford instead: per hop level it relaxes the frontier's outgoing edges,
  keeping each node's **best incoming confidence** — `O(max_depth · reachable_edges)`.

  - **Confidence** = the max over all paths of `product(reliability · decay(age))`.
    Every factor is `≤ 1`, so confidence is non-increasing along a path: a cycle can
    never improve it, which is why relaxation **terminates without path-array cycle
    tracking** (the `max_depth` cap and the edge budget are the operational bounds).
    Identical to the CTE's `max(conf)` for single-source (within-shared-ancestor max).
  - **Depth** = the minimum hop-distance at which a node is first reached (first
    relaxation level). Confidence and depth are **independent aggregates** — exactly
    the CTE's `max(conf)`, `min(depth)`. A node's best confidence may be found at a
    *later* level (a fresher/stronger longer path); the reported depth stays the
    min-hop reach. (Pairing depth with the max-conf path would change the contract —
    a separate ADR; council, codex.)
  - **Best-effort above a budget** (ADR-3): once the edge-visit budget is exceeded the
    walk halts and returns what it has, flagged `truncated`. Level-synchronous
    relaxation (candidates computed from the previous level's snapshot, then merged)
    keeps each iteration to exactly one hop, so the `max_depth` bound holds.

  Visibility (ADR-5): default-deny is enforced once, at the gate. This primitive
  optionally prunes by `scope` at the index when the caller supplies `:scopes`;
  with none it does not filter (mechanism/policy split). A refuted trace
  (`reward < 0`, T12) is not traversable at read time.
  """

  alias Swarm.Config
  alias Swarm.Repo

  @typedoc "A reached node: its id, best-path confidence, and shortest depth."
  @type hit :: %{id: integer(), confidence: float(), depth: integer()}

  @typedoc "A bounded walk: the hits plus whether the edge budget truncated it."
  @type result :: %{hits: [hit()], truncated: boolean()}

  @doc """
  Walk outward from `start_id` up to `max_depth` hops; return reached nodes
  (excluding the start) with their best-path confidence, ordered strongest-first.

  `opts`: `:scopes` — a list of allowed visibility scopes (index-level pruning);
  `:edge_budget` — override the configured per-walk edge-visit budget.
  """
  @spec traverse(integer(), pos_integer(), keyword()) :: [hit()]
  def traverse(start_id, max_depth, opts \\ []) do
    walk(start_id, max_depth, opts).hits
  end

  @doc """
  Like `traverse/3` but returns `%{hits, truncated}` — the ADR-3 best-effort
  contract. `truncated: true` means the edge-visit budget was hit and the result is
  partial (the answer-result algebra, T6, surfaces this).
  """
  @spec walk(integer(), pos_integer(), keyword()) :: result()
  def walk(start_id, max_depth, opts \\ [])
      when is_integer(start_id) and is_integer(max_depth) and max_depth > 0 do
    lambda = Config.decay_lambda()
    budget = Keyword.get(opts, :edge_budget) || Config.traverse_edge_budget()
    scopes = Keyword.get(opts, :scopes)

    state = %{
      conf: %{start_id => 1.0},
      depth: %{start_id => 0},
      frontier: [start_id],
      visited: 0,
      truncated: false
    }

    final =
      Enum.reduce_while(1..max_depth, state, fn level, st ->
        if st.frontier == [] do
          {:halt, st}
        else
          step(st, level, lambda, scopes, budget)
        end
      end)

    hits =
      final.conf
      |> Map.delete(start_id)
      |> Enum.map(fn {id, conf} ->
        %{id: id, confidence: conf, depth: Map.fetch!(final.depth, id)}
      end)
      |> Enum.sort_by(& &1.confidence, :desc)

    %{hits: hits, truncated: final.truncated}
  end

  # One hop level: fetch the frontier's outgoing edges, charge the budget, relax.
  @spec step(map(), pos_integer(), float(), [String.t()] | nil, pos_integer()) ::
          {:cont, map()} | {:halt, map()}
  defp step(st, level, lambda, scopes, budget) do
    edges = fetch_edges(st.frontier, lambda, scopes)
    visited = st.visited + length(edges)

    if visited > budget do
      # Best-effort: keep what we have, stop walking (ADR-3).
      {:halt, %{st | truncated: true}}
    else
      {conf, depth, next} = relax(edges, st.conf, st.depth, level)
      {:cont, %{st | conf: conf, depth: depth, frontier: next, visited: visited}}
    end
  end

  # Level-synchronous relaxation: compute ALL candidates from the previous level's
  # `conf` snapshot first (so this level's updates never feed this level's reads —
  # that is what keeps each iteration to exactly one hop), then merge by `max`.
  # Newly-improved nodes form the next frontier; `depth` is set once, on first reach.
  @spec relax([{integer(), integer(), float()}], map(), map(), pos_integer()) ::
          {map(), map(), [integer()]}
  defp relax(edges, conf, depth, level) do
    candidates =
      Enum.reduce(edges, %{}, fn {src, dst, factor}, acc ->
        cand = Map.fetch!(conf, src) * factor
        Map.update(acc, dst, cand, &max(&1, cand))
      end)

    Enum.reduce(candidates, {conf, depth, []}, fn {dst, cand}, {conf, depth, next} ->
      case Map.get(conf, dst) do
        nil -> {Map.put(conf, dst, cand), Map.put(depth, dst, level), [dst | next]}
        cur when cand > cur -> {Map.put(conf, dst, cand), depth, [dst | next]}
        _ -> {conf, depth, next}
      end
    end)
  end

  # The frontier's outgoing edges, each with its decayed reliability factor
  # `reliability · exp(-λ·age_days)`. `reward >= 0` excludes refuted traces (T12).
  # With `:scopes`, prune on the destination node's scope AND the edge's own scope.
  @spec fetch_edges([integer()], float(), [String.t()] | nil) ::
          [{integer(), integer(), float()}]
  defp fetch_edges(frontier, lambda, nil) do
    run(
      """
        SELECT e.src, e.dst,
               e.reliability * exp(-#{lambda_lit(lambda)} * EXTRACT(EPOCH FROM (now() - e.last_seen)) / 86400.0)
          FROM edge e
         WHERE e.src = ANY($1) AND e.reward >= 0
      """,
      [frontier]
    )
  end

  defp fetch_edges(frontier, lambda, scopes) when is_list(scopes) do
    run(
      """
        SELECT e.src, e.dst,
               e.reliability * exp(-#{lambda_lit(lambda)} * EXTRACT(EPOCH FROM (now() - e.last_seen)) / 86400.0)
          FROM edge e
          JOIN node n ON n.id = e.dst AND n.scope = ANY($2::text[])
         WHERE e.src = ANY($1) AND e.reward >= 0
           AND e.visibility_scope = ANY($2::text[])
      """,
      [frontier, scopes]
    )
  end

  @spec run(String.t(), list()) :: [{integer(), integer(), float()}]
  defp run(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, fn [src, dst, factor] -> {src, dst, factor} end)
  end

  # λ is a config float (not user input); inline it as a literal so the decay
  # expression stays a single parameter-free SQL fragment.
  @spec lambda_lit(float()) :: String.t()
  defp lambda_lit(lambda), do: :erlang.float_to_binary(lambda * 1.0, decimals: 12)
end
