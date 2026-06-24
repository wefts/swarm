# Retrieval stress measurement (data-impl Phase-1 verification). Run AFTER the slice
# is ingested + embedded. Measures retrieval latency under load (p50/p95/p99), the
# fragmentation probe at scale, and merge-under-load timing.
#
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex test/support/stress_query.exs

require Logger
Logger.configure(level: :warning)

alias Swarm.Graph.Retrieval
alias Swarm.Graph.Store
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Repo.start_link()
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

count = fn sql ->
  %{rows: [[n]]} = Repo.query!(sql)
  n
end

pctl = fn sorted, p ->
  n = length(sorted)
  if n == 0, do: 0.0, else: Enum.at(sorted, min(n - 1, trunc(p * n)))
end

IO.puts("== Retrieval stress ==")
articles = count.("SELECT count(*) FROM node WHERE type='article'")
chunks = count.("SELECT count(*) FROM chunk")
edges = count.("SELECT count(*) FROM edge")
vecs = count.("SELECT count(*) FROM node WHERE vec IS NOT NULL")
IO.puts("graph: #{articles} article nodes, #{edges} edges, #{chunks} chunks, #{vecs} nodes w/ vec\n")

# Build a query workload from real chunk text (first 8 words of N sampled chunks).
%{rows: rows} =
  Repo.query!("SELECT text FROM chunk WHERE length(text) > 80 ORDER BY node_id, ordinal LIMIT 60")

workload =
  rows
  |> Enum.map(fn [t] -> t |> String.split(~r/\s+/, trim: true) |> Enum.take(8) |> Enum.join(" ") end)
  |> Enum.uniq()

IO.puts("-- latency over #{length(workload)} real queries (incl. real bge-m3 query embed) --")

time_queries = fn label, opts ->
  times =
    Enum.map(workload, fn q ->
      t = System.monotonic_time(:microsecond)
      Retrieval.search(q, ["public"], opts)
      (System.monotonic_time(:microsecond) - t) / 1000.0
    end)

  s = Enum.sort(times)
  IO.puts("#{label}: p50 #{Float.round(pctl.(s, 0.5), 1)} ms | p95 #{Float.round(pctl.(s, 0.95), 1)} ms | " <>
          "p99 #{Float.round(pctl.(s, 0.99), 1)} ms | max #{Float.round(Enum.max(s), 1)} ms")
end

time_queries.("hybrid + traverse(d=2)", limit: 5, max_depth: 2)
time_queries.("hybrid, no expand    ", limit: 5, expand: false)
time_queries.("lexical-only, no exp ", limit: 5, expand: false, dense: false)

IO.puts("\n-- fragmentation probe (case-folded key collisions among article nodes) --")
%{rows: frag} =
  Repo.query!("""
  SELECT lower(key), count(*) FROM node WHERE type='article'
  GROUP BY lower(key) HAVING count(*) > 1 ORDER BY count(*) DESC LIMIT 10
  """)

if frag == [], do: IO.puts("0 collision groups (canonicalisation + alias table held)"),
  else: Enum.each(frag, fn [k, n] -> IO.puts("  #{k}: #{n}") end)

IO.puts("\n-- merge under load (re-point + chunk-union + re-aggregate timing) --")
# pick two real article nodes with chunks and time a merge (then it's gone — measurement only)
%{rows: pair} =
  Repo.query!("""
  SELECT n.key FROM node n WHERE n.type='article'
    AND EXISTS (SELECT 1 FROM chunk c WHERE c.node_id = n.id)
  ORDER BY n.id LIMIT 2
  """)

case pair do
  [[a], [b]] ->
    t = System.monotonic_time(:microsecond)
    {:ok, res} = Store.merge_nodes("article", a, b)
    ms = (System.monotonic_time(:microsecond) - t) / 1000.0
    IO.puts("merged #{inspect(a)} -> #{inspect(b)}: #{res.result}, #{res.edges} edges, #{Float.round(ms, 1)} ms")

  _ ->
    IO.puts("not enough chunked nodes to time a merge")
end
