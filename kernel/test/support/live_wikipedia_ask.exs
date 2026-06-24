# Live slice, ask half. Two honest measurements against the graph built by
# live_wikipedia_slice.exs, WITHOUT the ML service (the hive ML pillar is on the
# compose-internal network, unreachable from a host mix run):
#
#   1. Risk #2 (escalation): with the embedder down the gate uses its conservative
#      keyword fallback; we tally the tiers it picks for real queries.
#   2. The deterministic tier_tools GRAPH retrieval (Core.search/3) — no ML needed
#      — proving ingest→graph→retrieve→citations on real data.
#
# The full semantic gate + consilium path needs the ML service and is exercised in
# E2-verify against the (redeployed) hive stack. Run:
#
#   SWARM_DB_NAME=swarm_slice MIX_ENV=dev mix run --no-start \
#     test/support/live_wikipedia_ask.exs

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Swarm.Repo.start_link()
{:ok, _} = Swarm.Gate.Telemetry.start_link([])

# Deterministic "ML down": the embedder errors, so the gate degrades to keyword
# routing (its conservative floor), exactly as in a real embedder outage.
ml_down = fn _ -> {:error, :ml_down} end

queries = [
  "!!!",
  "show me albums",
  "find !Hero",
  "status of the knowledge base",
  "write me a poem about the sea",
  "what is the capital of France"
]

IO.puts("== Risk #2: gate tiers with ML DOWN (keyword fallback) ==\n")

tally =
  Enum.reduce(queries, %{}, fn q, acc ->
    d = Swarm.Gate.route(q, embedder: ml_down)
    IO.puts("  #{String.pad_trailing(inspect(q), 38)} -> tier=#{d.tier} reason=#{d.reason}")
    Map.update(acc, d.tier, 1, &(&1 + 1))
  end)

IO.puts("\n  tier tally: #{inspect(tally)}")
IO.puts("  (degraded floor biases to escalate-under-doubt — risk #2 in the raw)")

IO.puts("\n== Deterministic tier_tools graph retrieval (no ML) ==\n")

for q <- ["!!!", "Hero", "album", "Allmusic"] do
  hits = Swarm.Core.search(q, ["public"], limit: 5)
  IO.puts("Q: #{inspect(q)} -> #{length(hits)} hit(s)")
  for h <- Enum.take(hits, 5), do: IO.puts("   - #{h.type}/#{h.key}")
end
