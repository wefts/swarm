# Verify the relevance floor on live data: out-of-scope → not_found WITHOUT tanking
# in-scope recall, across a floor sweep. Also reports recall@1 (the magnet/ranking fix).
#
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex test/support/verify_floor.exs

require Logger
Logger.configure(level: :warning)

alias Swarm.Graph.Retrieval
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Repo.start_link()
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

# In-scope probes: first 9 words of real chunks, expected = that chunk's node key.
%{rows: rows} =
  Repo.query!("""
  SELECT n.key, c.text FROM chunk c JOIN node n ON n.id = c.node_id
  WHERE n.scope='public' AND length(c.text) > 80 ORDER BY c.node_id, c.ordinal
  """)

in_scope =
  rows
  |> Enum.map(fn [key, text] -> {key, text |> String.split(~r/\s+/, trim: true) |> Enum.take(9) |> Enum.join(" ")} end)
  |> Enum.uniq_by(fn {_k, q} -> q end)

out_scope = [
  "how do I cook a mushroom risotto",
  "what is the capital of France",
  "summarize the plot of the movie Inception",
  "explain the BLERG-9000 quantum fusion reactor",
  "what is the boiling point of mercury",
  "best exercises for lower back pain",
  "who won the 2024 election",
  "recipe for chocolate chip cookies",
  "how tall is Mount Everest",
  "translate good morning into Japanese"
]

IO.puts("== Relevance-floor verification ==")
IO.puts("in-scope probes: #{length(in_scope)}, out-of-scope probes: #{length(out_scope)}\n")
IO.puts("floor | out-of-scope rejected | in-scope recall@5 | in-scope recall@1")

for floor <- [0.40, 0.45, 0.50, 0.55] do
  rejected =
    Enum.count(out_scope, fn q ->
      %{status: s} = Retrieval.search(q, ["public"], floor: floor, expand: false)
      s == :not_found
    end)

  {r5, r1} =
    Enum.reduce(in_scope, {0, 0}, fn {key, q}, {a5, a1} ->
      %{memories: mems} = Retrieval.search(q, ["public"], floor: floor, limit: 5, expand: false)
      keys = Enum.map(mems, & &1.key)
      hit5 = if key in keys, do: 1, else: 0
      hit1 = if List.first(keys) == key, do: 1, else: 0
      {a5 + hit5, a1 + hit1}
    end)

  n = length(in_scope)
  o = length(out_scope)

  IO.puts(
    "#{:erlang.float_to_binary(floor, decimals: 2)}  |  #{rejected}/#{o} (#{Float.round(rejected * 100 / o, 0)}%)" <>
      "        |  #{r5}/#{n} (#{Float.round(r5 * 100 / n, 0)}%)" <>
      "      |  #{r1}/#{n} (#{Float.round(r1 * 100 / n, 0)}%)"
  )
end
