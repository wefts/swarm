# Answer-path harness: drives the FULL Core.ask pipeline (gate → hybrid retrieval
# with the relevance floor → composed answer + citations) so a tester judges the
# end-to-end answer, not just raw retrieval. Routing is pinned to tier_tools (a
# fixed gate embedder + prototype) so every probe exercises the retrieval→answer
# path; the dense arm still embeds the query via the real bge-m3 boundary.
#
#   QA_QUESTIONS="q1||q2" QA_SCOPES=public \
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex test/support/ask_probe.exs

require Logger
Logger.configure(level: :warning)

alias Swarm.Core
alias Swarm.Gate.Bands
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Repo.start_link()
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)
{:ok, _} = Swarm.Gate.Telemetry.start_link([])

scopes = String.split(System.get_env("QA_SCOPES", "public"), ",", trim: true)
viewer = System.get_env("QA_VIEWER", "")

questions =
  cond do
    f = System.get_env("QA_FILE") -> f |> File.read!() |> String.split("\n", trim: true)
    q = System.get_env("QA_QUESTIONS") -> String.split(q, "||", trim: true)
    true -> ["what is this knowledge base about", "how do I cook risotto"]
  end
  |> Enum.reject(&(String.starts_with?(String.trim(&1), "#") or String.trim(&1) == ""))

# Pin routing to tier_tools so each probe goes through retrieval→answer.
opts = [
  scopes: scopes,
  viewer: viewer,
  prototypes: [%{intent: :recall, tier: :tier_tools, text: "kb"}],
  embedder: fn _ -> {:ok, [1.0, 0.0, 0.0]} end,
  bands: %Bands{handle: 0.5}
]

IO.puts("== Core.ask answer-path probe (scopes=#{inspect(scopes)}#{if viewer != "", do: " viewer=#{viewer}"}) ==\n")

for q <- questions do
  a = Core.ask(q, opts)
  IO.puts("Q: #{q}")
  IO.puts("   status: #{a.status}  | tier: #{a.tier} | confidence: #{a.confidence}")
  IO.puts("   answer: #{a.answer}")

  a.citations
  |> Enum.take(5)
  |> Enum.with_index(1)
  |> Enum.each(fn {c, i} ->
    IO.puts("   cite #{i}: #{c.source}:#{c.ref}  (#{Float.round(c.confidence, 3)})")
  end)

  IO.puts("")
end
