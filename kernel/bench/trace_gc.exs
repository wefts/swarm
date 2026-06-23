# Trace-GC saturation bench (T11). Shows that under continuous trace churn the
# working set (and the cost of a graph scan over it) stays BOUNDED with GC reap,
# and GROWS without it — the practical half of N1.
#
# Run (Repo only) against a throwaway DB (it TRUNCATEs the graph):
#   SWARM_DB_NAME=swarm_bench SWARM_DB_HOST=localhost \
#     mix run --no-start bench/trace_gc.exs

alias Swarm.Graph.GC
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Repo.start_link(pool_size: 2, timeout: 120_000)

Repo.query!("TRUNCATE node, edge, edge_provenance, outbox, dead_letter RESTART IDENTITY CASCADE")
Repo.query!("INSERT INTO node (type, scope, reliability) SELECT 'bench','public',1.0 FROM generate_series(1,2)")

# One churn round: insert `n` traces, then age MOST of them far past reinforcement
# (they have evaporated). A real system churns like this continuously.
churn = fn round, n ->
  Repo.query!(
    """
    INSERT INTO edge (src, dst, type, reliability, last_seen, visibility_scope, seen_count)
    SELECT 1, 2, 'b' || $1 || '_' || g, 0.9,
           CASE WHEN g % 10 = 0 THEN now() ELSE now() - interval '2000 days' END,
           'public', 1
      FROM generate_series(1, $2) AS g
    ON CONFLICT DO NOTHING
    """,
    [Integer.to_string(round), n]
  )
end

# crude scan cost: count(*) over the edge table (proxy for an O(N) traversal pass)
scan_ms = fn ->
  {us, _} = :timer.tc(fn -> Repo.query!("SELECT count(*) FROM edge") end)
  Float.round(us / 1000, 2)
end

edges = fn ->
  %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM edge")
  n
end

rounds = 5

# Arm A — NO GC: 5 rounds of churn, never reaped. Evaporated traces accumulate.
for r <- 1..rounds, do: churn.(r, 2000)
no_gc = %{edges: edges.(), scan: scan_ms.()}

# Arm B — WITH GC: same churn, reaping the evaporated traces after each round.
Repo.query!("TRUNCATE edge, edge_provenance RESTART IDENTITY CASCADE")
for r <- 1..rounds do
  churn.(r, 2000)
  GC.reap(floor: 0.05)
end

with_gc = %{edges: edges.(), scan: scan_ms.()}

IO.puts("\n# Trace-GC saturation bench  (#{rounds} churn rounds × 2000 traces, ~90% evaporated)\n")
IO.puts("| arm | edges retained | scan ms |")
IO.puts("| --- | ---: | ---: |")
IO.puts("| NO GC | #{no_gc.edges} | #{no_gc.scan} |")
IO.puts("| WITH GC | #{with_gc.edges} | #{with_gc.scan} |")

IO.puts("""

Reading: NO GC retains every churned trace (~#{rounds * 2000}); WITH GC keeps only
the still-reinforced ~10% (~#{rounds * 200}) — the evaporated 90% are reaped, so the
working set and the scan cost over it stay bounded under continuous churn. ρ + floor
are re-derivable per corpus (swarm ADR-9 / the GC moduledoc).
""")
