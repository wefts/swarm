# Recall measurement (swarm ADR-14 §5, data-impl Card 5) — REVISED after a
# decorrelated critic council (codex + gemini both flagged the first cut as rigged:
# stripping title words guaranteed the title-ILIKE baseline scored 0 by construction).
#
# This version is FAIR: probes are NATURAL, unmodified phrases lifted verbatim from a
# chunk (a realistic "paste a sentence you half-remember" query) — title words are NOT
# stripped, so the baseline gets every signal it actually uses. We report three rungs
# so the comparison is honest about WHERE the lift comes from:
#   1. title-ILIKE   — the deployed baseline (Core.search, matches node KEY only)
#   2. lexical-only  — our hybrid with the dense arm OFF (tsvector over chunk.text)
#   3. hybrid        — lexical ∥ dense, RRF-fused
# recall@k and MRR@k, relevant node = the probe's source chunk's node.
#
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex test/support/live_recall_measure.exs

require Logger
Logger.configure(level: :warning)

alias Swarm.Core
alias Swarm.Graph.Retrieval
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Repo.start_link()
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

k = String.to_integer(System.get_env("RECALL_K", "5"))
scopes = ["public"]

%{rows: rows} =
  Repo.query!("""
  SELECT k.node_id, k.text
  FROM chunk k
  WHERE length(k.text) > 80
  ORDER BY k.node_id, k.ordinal
  """)

# A natural probe: the first 10 words of a chunk, UNMODIFIED (title words included).
probe_of = fn text ->
  words = String.split(text, ~r/\s+/, trim: true)
  if length(words) >= 6, do: words |> Enum.take(10) |> Enum.join(" "), else: nil
end

probes =
  rows
  |> Enum.map(fn [node_id, text] -> {node_id, probe_of.(text)} end)
  |> Enum.reject(fn {_id, p} -> is_nil(p) end)
  |> Enum.uniq_by(fn {_id, p} -> p end)

# Rank of the relevant node in a result list, or nil if absent within k.
rank_of = fn ids, node_id -> Enum.find_index(ids, &(&1 == node_id)) end

title_ids = fn phrase -> Core.search(phrase, scopes, limit: k) |> Enum.map(& &1.id) end

retr_ids = fn phrase, dense? ->
  %{memories: m, expanded: e} =
    Retrieval.search(phrase, scopes, limit: k, dense: dense?, max_depth: 1)

  Enum.map(m, & &1.node_id) ++ Enum.map(e, & &1.id)
end

score = fn ids_fun ->
  Enum.reduce(probes, {0, 0.0}, fn {node_id, phrase}, {hits, mrr} ->
    case rank_of.(ids_fun.(phrase), node_id) do
      nil -> {hits, mrr}
      r when r < k -> {hits + 1, mrr + 1.0 / (r + 1)}
      _ -> {hits, mrr}
    end
  end)
end

n = length(probes)
pct = fn x -> if n > 0, do: Float.round(x * 100 / n, 1), else: 0.0 end
avg = fn x -> if n > 0, do: Float.round(x / n, 3), else: 0.0 end

{tb, tm} = score.(fn p -> title_ids.(p) end)
{lb, lm} = score.(fn p -> retr_ids.(p, false) end)
{hb, hm} = score.(fn p -> retr_ids.(p, true) end)

IO.puts("== Recall measurement (FAIR; natural probes, k=#{k}) ==")
IO.puts("probes: #{n} verbatim chunk phrases (title words NOT stripped)\n")
IO.puts("                                   recall@#{k}        MRR@#{k}")
IO.puts("1. title-ILIKE  (Core.search)      #{pct.(tb)}%  (#{tb}/#{n})    #{avg.(tm)}")
IO.puts("2. lexical-only (chunk tsvector)   #{pct.(lb)}%  (#{lb}/#{n})    #{avg.(lm)}")
IO.puts("3. hybrid       (lexical ∥ dense)  #{pct.(hb)}%  (#{hb}/#{n})    #{avg.(hm)}")
IO.puts("\ncontent retrieval vs title baseline: +#{pct.(hb) - pct.(tb)} pp recall")
IO.puts("dense arm's marginal lift over lexical-only: +#{pct.(hb) - pct.(lb)} pp recall")
IO.puts("\nNOTE: verbatim probes favour lexical; the dense arm's paraphrase advantage")
IO.puts("needs paraphrase/NL-question probes (LLM-generated) — a Phase-2 measurement.")
