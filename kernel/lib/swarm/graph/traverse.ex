defmodule Swarm.Graph.Traverse do
  @moduledoc """
  Bounded graph traversal — the primitive the gate later uses as "thinking".

  The engine does the walk (recursive CTE), not an app-code fetch loop: per-edge
  decay `exp(-λ·age)` and chain-confidence `product(reliability·decay)` are
  computed inside the query; per-node aggregation keeps the strongest path
  (`max` — the within-shared-ancestor rule of ADR-3, since all paths share the
  start). Combining independent origins is noisy-OR via `Swarm.Graph.Confidence`.

  Visibility (ADR-5): default-deny is enforced once, at the gate. This primitive
  optionally prunes by `scope` at the index when the caller supplies `:scopes`;
  with none, it does not filter (mechanism/policy split).

  Performance: depth is capped and cycles are pruned (a path-array check), so the
  walk terminates. Path enumeration is still worst-case exponential in branching
  factor — keep `max_depth` small. If traversal becomes the dominant access
  pattern, switch to a visited-set BFS (storage-spike caveat), do not raise the
  cap blindly.
  """

  alias Swarm.Config
  alias Swarm.Repo

  @typedoc "A reached node: its id, best-path confidence, and shortest depth."
  @type hit :: %{id: integer(), confidence: float(), depth: integer()}

  @doc """
  Walk outward from `start_id` up to `max_depth` hops. Returns reached nodes
  (excluding the start) with their best-path confidence, ordered strongest-first.

  `opts`: `:scopes` — a list of allowed visibility scopes; when given, only edges
  into nodes with those scopes are followed (index-level pruning).
  """
  @spec traverse(integer(), pos_integer(), keyword()) :: [hit()]
  def traverse(start_id, max_depth, opts \\ [])
      when is_integer(start_id) and is_integer(max_depth) and max_depth > 0 do
    lambda = Config.decay_lambda()

    case Keyword.get(opts, :scopes) do
      nil -> run(unscoped_sql(), [start_id, lambda, max_depth])
      scopes when is_list(scopes) -> run(scoped_sql(), [start_id, lambda, max_depth, scopes])
    end
  end

  @spec run(String.t(), list()) :: [hit()]
  defp run(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [id, confidence, depth] ->
      %{id: id, confidence: confidence, depth: depth}
    end)
  end

  # Decay is applied per hop on `last_seen` (re-confirmation refreshes the clock,
  # aligning confidence with reinforcement). `is_cycle`/`path` prevent revisiting
  # a node along the same path.
  @recursive_step """
        SELECT e.dst,
               w.conf * e.reliability *
                 exp(-$2::float8 * EXTRACT(EPOCH FROM (now() - e.last_seen)) / 86400.0),
               w.depth + 1,
               w.path || e.dst,
               e.dst = ANY(w.path)
          FROM walk w
          JOIN edge e ON e.src = w.id
  """

  @aggregate """
    SELECT id, max(conf) AS confidence, min(depth) AS depth
      FROM walk
     WHERE depth > 0 AND NOT is_cycle
     GROUP BY id
     ORDER BY confidence DESC
  """

  @spec unscoped_sql() :: String.t()
  defp unscoped_sql do
    """
    WITH RECURSIVE walk(id, conf, depth, path, is_cycle) AS (
      SELECT $1::bigint, 1.0::float8, 0, ARRAY[$1::bigint], false
      UNION ALL
    #{@recursive_step}
         WHERE w.depth < $3::int AND NOT w.is_cycle
    )
    #{@aggregate}
    """
  end

  @spec scoped_sql() :: String.t()
  defp scoped_sql do
    """
    WITH RECURSIVE walk(id, conf, depth, path, is_cycle) AS (
      SELECT $1::bigint, 1.0::float8, 0, ARRAY[$1::bigint], false
      UNION ALL
    #{@recursive_step}
          JOIN node n ON n.id = e.dst AND n.scope = ANY($4::text[])
         WHERE w.depth < $3::int AND NOT w.is_cycle
    )
    #{@aggregate}
    """
  end
end
