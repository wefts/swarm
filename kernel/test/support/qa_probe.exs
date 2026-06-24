# QA probe harness (data-impl Phase-1 verification). Runs a batch of natural-language
# questions through hybrid retrieval against the live, embedded slice and prints the
# result readably so a (human or agent) tester can judge whether the right knowledge
# surfaced — and, for negative probes, whether the system correctly finds NOTHING.
#
# Many questions per BEAM boot (one ML connection). Questions come from a file
# (QA_FILE, one per line; `#` comment lines ignored; an optional TAB-separated second
# field is the expected node key for auto-scoring) or from QA_QUESTIONS (`||`-joined).
#
#   QA_FILE=/path/questions.txt RECALL_K=5 \
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex test/support/qa_probe.exs

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
scopes = String.split(System.get_env("QA_SCOPES", "public"), ",", trim: true)

questions =
  cond do
    f = System.get_env("QA_FILE") ->
      f
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&(String.starts_with?(String.trim(&1), "#") or String.trim(&1) == ""))

    q = System.get_env("QA_QUESTIONS") ->
      String.split(q, "||", trim: true)

    true ->
      ["what is the moon", "who discovered gravity"]
  end

parse = fn line ->
  case String.split(line, "\t", parts: 2) do
    [q, expected] -> {String.trim(q), String.trim(expected)}
    [q] -> {String.trim(q), nil}
  end
end

trunc_span = fn text -> text |> String.slice(0, 140) |> String.replace(~r/\s+/, " ") end

IO.puts("== QA probe (k=#{k}, scopes=#{inspect(scopes)}) ==")
IO.puts("graph: #{Repo.query!("SELECT count(*) FROM node WHERE type='article'").rows |> hd |> hd} article nodes, " <>
        "#{Repo.query!("SELECT count(*) FROM chunk").rows |> hd |> hd} chunks\n")

{hit, miss, total} =
  Enum.reduce(questions, {0, 0, 0}, fn line, {hit, miss, total} ->
    {q, expected} = parse.(line)
    %{status: status, memories: mems, expanded: exp} = Retrieval.search(q, scopes, limit: k, max_depth: 1)

    # title-ILIKE baseline (the deployed Core.search) for contrast
    base = Core.search(q, scopes, limit: 3) |> Enum.map(& &1.key)

    IO.puts("Q: #{q}")
    IO.puts("   status: #{status}   baseline(title-ILIKE) top3: #{inspect(base)}")

    mems
    |> Enum.with_index(1)
    |> Enum.each(fn {m, i} ->
      span = m.spans |> List.first() |> case do
        nil -> "(no span)"
        s -> trunc_span.(s.text)
      end

      IO.puts("   #{i}. [rel #{m.relevance} | score #{Float.round(m.score, 4)} | conf #{m.confidence}] #{m.key}")
      IO.puts("        :: #{span}")
    end)

    if exp != [] and exp != nil do
      neigh = exp |> Enum.take(5) |> Enum.map(& &1.id)
      IO.puts("   neighbours(node ids via traversal): #{inspect(neigh)}")
    end

    # auto-score against an expected node key, if provided
    {dh, dm} =
      case expected do
        nil ->
          {0, 0}

        key ->
          got = Enum.any?(mems, &(&1.key == key))
          IO.puts("   EXPECTED: #{key} → #{if got, do: "HIT", else: "MISS"}")
          if got, do: {1, 0}, else: {0, 1}
      end

    IO.puts("")
    {hit + dh, miss + dm, total + 1}
  end)

IO.puts("-- summary --")
IO.puts("questions: #{total}")
if hit + miss > 0, do: IO.puts("labeled recall@#{k}: #{hit}/#{hit + miss}")
