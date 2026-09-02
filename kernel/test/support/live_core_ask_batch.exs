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
# It also records measurement conditions and refuses to compare against a baseline
# whose database, env, code revision, or tier-gate/fleet config differ.

require Logger

defmodule LiveCoreAskBatch.Conditions do
  @moduledoc false

  def build(repo, tier_gate) do
    %{
      database: repo.config()[:database],
      swarm_env: System.get_env("SWARM_ENV", ""),
      code_revision: code_revision(),
      code_dirty?: code_dirty?(),
      consilium: normalize(Application.get_env(:swarm, :consilium, [])),
      tier_gate: normalize(tier_gate),
      retrieval: normalize(Application.get_env(:swarm, :retrieval, [])),
      ml_prewarm: normalize(Application.get_env(:swarm, :ml_prewarm, [])),
      ml_address: System.get_env("SWARM_ML_ADDRESS", "")
    }
  end

  def condition_hash(conditions) do
    conditions
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def compare_conditions!(current, current_hash) do
    case System.get_env("QA_BASELINE_LOG") do
      nil ->
        :ok

      "" ->
        :ok

      path ->
        expected = baseline_conditions!(path)
        expected_hash = Map.fetch!(expected, "condition_hash")

        if expected_hash != current_hash do
          raise """
          live_core_ask_batch: refusing comparison because conditions differ
          baseline=#{path}
          baseline_hash=#{expected_hash}
          current_hash=#{current_hash}
          baseline_conditions=#{inspect(expected)}
          current_conditions=#{inspect(current)}
          """
        end
    end
  end

  defp code_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {rev, 0} -> String.trim(rev)
      _ -> "unknown"
    end
  end

  defp code_dirty? do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> false
      {_, 0} -> true
      _ -> true
    end
  end

  defp baseline_conditions!(path) do
    path
    |> File.stream!()
    |> Enum.find(&String.starts_with?(&1, "CONDITIONS\t"))
    |> case do
      nil ->
        raise "live_core_ask_batch: baseline #{path} has no CONDITIONS line"

      line ->
        line
        |> String.trim()
        |> String.replace_prefix("CONDITIONS\t", "")
        |> Jason.decode!()
    end
  end

  defp normalize(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)
    else
      Enum.map(value, &normalize/1)
    end
  end

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)
  end

  defp normalize(value) when is_atom(value), do: to_string(value)
  defp normalize(value), do: value
end

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

conditions = LiveCoreAskBatch.Conditions.build(Repo, tier_gate)
condition_hash = LiveCoreAskBatch.Conditions.condition_hash(conditions)
LiveCoreAskBatch.Conditions.compare_conditions!(conditions, condition_hash)

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

IO.puts("CONDITIONS\t#{Jason.encode!(Map.put(conditions, :condition_hash, condition_hash))}")

IO.puts(
  "== live Core.ask batch db=#{conditions.database} revision=#{conditions.code_revision} hash=#{condition_hash} scopes=#{inspect(scopes)} questions=#{length(questions)} =="
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
  "SUMMARY\tcondition_hash=#{condition_hash}\tcount=#{length(results)}\tfound=#{found}\tstructured=#{structured}\tp50_ms=#{p50}\tp90_ms=#{p90}\tp99_ms=#{p99}\ttotal_ms=#{total_ms}"
)
