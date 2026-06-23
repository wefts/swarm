# Confidence-math saturation spike (T1) — dense-graph independence-grouping bench.
#
# Question (board/doing/T1): on a saturated graph, does computing confidence
# collapse, and is the cost in TRAVERSAL (the recursive-CTE path enumeration) or
# in INDEPENDENCE GROUPING (ADR-3 step 2, the named O(hard) open problem)?
#
# Run (Repo only — the full app's gRPC port clashes with a running kernel) against
# a throwaway DB (it TRUNCATEs the graph tables per scenario):
#   SWARM_DB_NAME=swarm_bench SWARM_DB_HOST=localhost \
#     mix run --no-start bench/confidence_saturation.exs
#
# It is a MEASUREMENT spike, not a feature; never point it at real data.

alias Swarm.{Repo, Graph.Traverse, Graph.Confidence}

# --no-start skips the swarm app (its gRPC port clashes with a running kernel),
# so bring up just the DB-connection stack the Repo needs. A generous default
# query timeout lets the big generators finish; per-measurement caps (below) are
# applied with SET LOCAL so a runaway query aborts cleanly without churning the
# pool.
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Repo.start_link(pool_size: 2, timeout: 300_000)

budget_ms = 1_000
cap_ms = 20_000

# A layered DAG: `layers` layers of `width` nodes; every node links to `fanout`
# random nodes in the next layer.
#   edges          = width * (layers - 1) * fanout      (raw size)
#   paths to sink ~ fanout ^ (layers - 1)               (path multiplicity)
# Two axes, varied independently so the knee can be attributed:
#   * SIZE axis    — many edges, fanout=2 (low overlap): pure graph scaling.
#   * DENSITY axis — modest edges, high fanout/depth: path count explodes. The
#     adversarial case for independence grouping.
scenarios = [
  # label,                width, layers, fanout
  {"size  ~1e3  f2 d5",     100,     6,     2},
  {"size  ~1e4  f2 d5",   1_000,     6,     2},
  {"size  ~1e5  f2 d5",  10_000,     6,     2},
  {"size  ~1e6  f2 d5", 100_000,     6,     2},
  {"dense ~8e3  f4 d7",   1_000,     8,     4},
  {"dense ~5e4  f6 d7",   1_000,     8,     6},
  {"dense ~9e4  f8 d9",   1_000,    10,     8},
  {"dense ~1e5 f12 d11",  1_000,    12,    12}
]

defmodule B do
  alias Swarm.Repo

  # Run `fun` (one or more DB calls on the same connection) under a server-side
  # statement_timeout of `cap` ms. Returns the value, or :overflow if it was
  # cancelled / errored. SET LOCAL scopes the cap to this transaction only, so
  # the generators stay uncapped and the pool is never disconnected.
  def capped(fun, cap) do
    res =
      try do
        Repo.transaction(
          fn ->
            Repo.query!("SET LOCAL statement_timeout = '#{cap}'")
            fun.()
          end,
          timeout: cap + 60_000
        )
      rescue
        _ -> :error
      catch
        :exit, _ -> :error
      end

    case res do
      {:ok, val} -> val
      _ -> :overflow
    end
  end

  def truncate! do
    Repo.query!("TRUNCATE node, edge, edge_provenance, outbox RESTART IDENTITY CASCADE")
  end

  # Build a layered DAG in-engine. Node ids are contiguous after RESTART IDENTITY:
  # layer L (0-based) owns ids [L*width+1 .. (L+1)*width]. Duplicate random
  # targets collide on the (src,dst,type,scope) natural key → ON CONFLICT skips
  # them, so the realized edge count (returned) is reported, not the nominal one.
  def generate!(width, layers, fanout) do
    Repo.query!(
      "INSERT INTO node (type, scope, reliability) " <>
        "SELECT 'bench','public',1.0 FROM generate_series(1, $1)",
      [width * layers]
    )

    Repo.query!(
      """
      INSERT INTO edge (src, dst, type, reliability, last_seen, visibility_scope)
      SELECT (L*$1 + w),
             ((L+1)*$1 + 1 + floor(random()*$1)::int),
             'bench', 0.9, now(), 'public'
        FROM generate_series(0, $2-2) AS L,
             generate_series(1, $1)   AS w,
             generate_series(1, $3)   AS f
      ON CONFLICT DO NOTHING
      """,
      [width, layers, fanout]
    )

    # ANALYZE after the bulk load — without fresh stats the planner sees
    # reltuples≈0 and seq-scans the recursive join, which is a measurement
    # artifact, not the traversal's intrinsic cost.
    Repo.query!("ANALYZE node, edge")

    %{rows: [[e]]} = Repo.query!("SELECT count(*) FROM edge")
    e
  end

  # Internal blowup: rows the recursive `walk` CTE materializes for a depth-`d`
  # traversal from `start`. This is the cost the aggregated output hides.
  def walk_rows(start, d) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        WITH RECURSIVE walk(id, depth, path, is_cycle) AS (
          SELECT $1::bigint, 0, ARRAY[$1::bigint], false
          UNION ALL
          SELECT e.dst, w.depth+1, w.path || e.dst, e.dst = ANY(w.path)
            FROM walk w JOIN edge e ON e.src = w.id
           WHERE w.depth < $2::int AND NOT w.is_cycle
        )
        SELECT count(*) FROM walk
        """,
        [start, d]
      )

    n
  end

  # Enumerate the actual deepest-layer paths (node arrays) — the input the ADR-3
  # independence-grouping step would have to consume.
  def enumerate_paths(start, d) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE walk(id, depth, path, is_cycle) AS (
          SELECT $1::bigint, 0, ARRAY[$1::bigint], false
          UNION ALL
          SELECT e.dst, w.depth+1, w.path || e.dst, e.dst = ANY(w.path)
            FROM walk w JOIN edge e ON e.src = w.id
           WHERE w.depth < $2::int AND NOT w.is_cycle
        )
        SELECT path FROM walk WHERE depth = $2::int AND NOT is_cycle
        """,
        [start, d]
      )

    Enum.map(rows, fn [p] -> p end)
  end

  # ADR-3 step 2 prototype: partition paths into independence groups (paths that
  # share any interior ancestor go in one group), then combine per ADR-3 (max
  # within group, noisy-OR across). Union-find over shared ancestors — the honest
  # cost of the open problem, GIVEN the enumerated path set.
  def group_and_combine(paths) do
    n = length(paths)
    parent = :counters.new(max(n, 1), [])
    for i <- 0..(n - 1)//1, do: :counters.put(parent, i + 1, i)

    find = fn find, x ->
      px = :counters.get(parent, x + 1)
      if px == x, do: x, else: find.(find, px)
    end

    union = fn a, b ->
      ra = find.(find, a)
      rb = find.(find, b)
      if ra != rb, do: :counters.put(parent, ra + 1, rb)
    end

    idx = Enum.with_index(paths)

    Enum.reduce(idx, %{}, fn {p, i}, seen ->
      interior = p |> Enum.drop(1) |> Enum.drop(-1)

      Enum.reduce(interior, seen, fn node, acc ->
        case acc do
          %{^node => j} ->
            union.(i, j)
            acc

          _ ->
            Map.put(acc, node, i)
        end
      end)
    end)

    # tuple, not list — list indexing here would make grouping O(P²) and inflate
    # the measured grouping cost (an implementation artifact, not intrinsic).
    confs_t = paths |> Enum.map(fn p -> :math.pow(0.9, length(p) - 1) end) |> List.to_tuple()

    groups =
      idx
      |> Enum.group_by(fn {_p, i} -> find.(find, i) end, fn {_p, i} -> elem(confs_t, i) end)
      |> Map.values()

    {Confidence.combine(groups), length(groups)}
  end

  # median wall-time (ms) of `fun` over `n` runs; :timeout if any run returned
  # :overflow (a capped query was cancelled).
  def timed(fun, n) do
    samples =
      for _ <- 1..n do
        {us, res} = :timer.tc(fun)
        if res == :overflow, do: :timeout, else: us / 1000
      end

    if Enum.any?(samples, &(&1 == :timeout)),
      do: :timeout,
      else: samples |> Enum.sort() |> Enum.at(div(n, 2))
  end
end

fmt = fn
  :timeout -> ">cap"
  :overflow -> ">cap"
  :skip -> "—"
  nil -> "—"
  n when is_float(n) -> :erlang.float_to_binary(n, decimals: 1)
  n -> to_string(n)
end

IO.puts(
  "\n# Confidence saturation bench  (budget #{budget_ms} ms / query, DB cap #{cap_ms} ms)\n"
)

IO.puts("| scenario | edges | depth | traverse ms | walk rows | paths@sink | group ms | groups | knee |")
IO.puts("|---|---:|---:|---:|---:|---:|---:|---:|---|")

for {label, width, layers, fanout} <- scenarios do
  B.truncate!()
  edges = B.generate!(width, layers, fanout)
  depth = layers - 1
  start = 1

  trav_ms = B.timed(fn -> B.capped(fn -> Traverse.traverse(start, depth) end, cap_ms) end, 3)
  walk = B.capped(fn -> B.walk_rows(start, depth) end, cap_ms)

  {paths, grp_ms, groups} =
    case walk do
      w when is_integer(w) and w < 2_000_000 ->
        case B.capped(fn -> B.enumerate_paths(start, depth) end, cap_ms) do
          ps when is_list(ps) ->
            gm = B.timed(fn -> B.group_and_combine(ps) end, 3)
            gc = if is_float(gm), do: elem(B.group_and_combine(ps), 1), else: nil
            {length(ps), gm, gc}

          _ ->
            {:overflow, :skip, :skip}
        end

      _ ->
        {:skip, :skip, :skip}
    end

  knee =
    cond do
      trav_ms == :timeout -> "TRAVERSAL"
      is_float(trav_ms) and trav_ms > budget_ms -> "TRAVERSAL"
      grp_ms == :timeout -> "GROUPING"
      is_float(grp_ms) and grp_ms > budget_ms -> "GROUPING"
      true -> "ok"
    end

  IO.puts(
    "| #{label} | #{edges} | #{depth} | #{fmt.(trav_ms)} | #{fmt.(walk)} | #{fmt.(paths)} | #{fmt.(grp_ms)} | #{fmt.(groups)} | #{knee} |"
  )
end

# --- Part 2: isolate INDEPENDENCE GROUPING (the named open problem) ------------
# The DAG above is single-source, so grouping is the degenerate one-group case.
# Here we feed group_and_combine a MULTI-ORIGIN path set with partial ancestor
# overlap, so partitioning does real work, and scale P independently of any
# traversal. This answers: given the paths, is step-2 grouping itself the wall?
defmodule PathGen do
  # `origins` independent sources; each path picks an origin, then `len` interior
  # ancestors from a shared pool of `pool` nodes, then the common sink. Group
  # count is controlled by pool vs P·len: a pool ≫ P·len yields mostly-unique
  # ancestors → MANY independence groups (the regime that stresses the partition
  # and the cross-group noisy-OR fold); a small pool fuses everything into one.
  def paths(num, origins, len, pool) do
    :rand.seed(:exsss, {num, origins, pool})
    sink = 100_000_000

    for _ <- 1..num do
      origin = :rand.uniform(origins)
      interior = for _ <- 1..len, do: 1_000 + :rand.uniform(pool)
      [origin | interior] ++ [sink]
    end
  end
end

IO.puts("\n# Independence-grouping isolation  (multi-origin, P paths)\n")
IO.puts("| paths P | origins | len | pool | group+combine ms | groups |")
IO.puts("|---:|---:|---:|---:|---:|---:|")

# Spread across group-count regimes: one fused group → many independent groups.
for {p, origins, len, pool} <- [
      {100_000, 50, 5, 200},
      {100_000, 1_000, 2, 5_000_000},
      {100_000, 10_000, 1, 50_000_000},
      {300_000, 10_000, 1, 50_000_000},
      {300_000, 50_000, 1, 200_000_000}
    ] do
  ps = PathGen.paths(p, origins, len, pool)
  ms = B.timed(fn -> B.group_and_combine(ps) end, 3)
  {_c, g} = B.group_and_combine(ps)
  IO.puts("| #{p} | #{origins} | #{len} | #{pool} | #{fmt.(ms)} | #{g} |")
end

IO.puts("\n(done)\n")
