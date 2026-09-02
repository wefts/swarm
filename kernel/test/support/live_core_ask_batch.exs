# Live Core.ask batch runner for deployed-path measurements.
#
# Use with Hive's compose-derived environment, not hand-copied variables:
#
#   eval "$(SWARM_ENV=staging ../hive/scripts/kernel-measure-env)"
#   QA_FILE=/tmp/questions.txt mise exec -- mix run --no-start test/support/live_core_ask_batch.exs
#
# This harness deliberately does not force prototypes, gate opts, scopes, retrieval
# arms, or model callbacks. It fails loudly if the tier gate is not actually enabled,
# because measuring compiled defaults has repeatedly produced false conclusions.

require Logger

Logger.configure(level: :info)

alias Swarm.Core
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:swarm)

tier_gate = Application.get_env(:swarm, :tier_gate, [])

unless Keyword.get(tier_gate, :enabled, false) == true do
  raise "live_core_ask_batch: SWARM_TIER_GATE_ENABLED is not active"
end

unless Keyword.get(tier_gate, :network_serve, false) == true do
  raise "live_core_ask_batch: SWARM_TIER_GATE_NETWORK_SERVE is not active"
end

unless Keyword.get(tier_gate, :who_serve, false) == true do
  raise "live_core_ask_batch: SWARM_TIER_GATE_WHO_SERVE is not active"
end

case Keyword.get(tier_gate, :network_min_corroboration) do
  n when is_integer(n) and n >= 1 -> :ok
  other -> raise "live_core_ask_batch: network_min_corroboration unset/invalid: #{inspect(other)}"
end

scopes =
  case System.get_env("QA_SCOPES") do
    nil ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT DISTINCT scope
          FROM node
          WHERE scope IS NOT NULL AND scope <> ''
          ORDER BY scope
          """,
          []
        )

      Enum.map(rows, fn [scope] -> scope end)

    value ->
      String.split(value, ",", trim: true)
  end

viewer = System.get_env("QA_VIEWER", "")

questions =
  cond do
    file = System.get_env("QA_FILE") ->
      File.read!(file)

    qs = System.get_env("QA_QUESTIONS") ->
      String.replace(qs, "||", "\n")

    true ->
      raise "live_core_ask_batch: set QA_FILE or QA_QUESTIONS"
  end
  |> String.split("\n", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

IO.puts(
  "== live Core.ask batch db=#{Repo.config()[:database]} scopes=#{inspect(scopes)} questions=#{length(questions)} =="
)

started_all = System.monotonic_time(:millisecond)

results =
  Enum.map(questions, fn question ->
    started = System.monotonic_time(:millisecond)
    answer = Core.ask(question, scopes: scopes, viewer: viewer)
    duration_ms = System.monotonic_time(:millisecond) - started

    citations =
      answer.citations
      |> Enum.take(4)
      |> Enum.map(fn c -> "#{c.source}:#{c.ref}" end)
      |> Enum.join(" | ")

    IO.puts(
      [
        "RESULT",
        "duration_ms=#{duration_ms}",
        "tier=#{answer.tier}",
        "status=#{answer.status}",
        "confidence=#{answer.confidence}",
        "question=#{inspect(question)}",
        "answer=#{inspect(answer.answer)}",
        "citations=#{inspect(citations)}"
      ]
      |> Enum.join("\t")
    )

    %{duration_ms: duration_ms, tier: answer.tier, status: answer.status}
  end)

total_ms = System.monotonic_time(:millisecond) - started_all
structured = Enum.count(results, &(&1.tier == "structured" and &1.status == :found))
found = Enum.count(results, &(&1.status == :found))
durations = Enum.map(results, & &1.duration_ms) |> Enum.sort()

p50 = Enum.at(durations, div(length(durations) - 1, 2), 0)
p90 = Enum.at(durations, max(0, ceil(length(durations) * 0.9) - 1), 0)
p99 = Enum.at(durations, max(0, ceil(length(durations) * 0.99) - 1), 0)

IO.puts(
  "SUMMARY\tcount=#{length(results)}\tfound=#{found}\tstructured=#{structured}\tp50_ms=#{p50}\tp90_ms=#{p90}\tp99_ms=#{p99}\ttotal_ms=#{total_ms}"
)
