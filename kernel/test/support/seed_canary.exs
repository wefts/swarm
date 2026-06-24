# Seed a PRIVATE canary node with distinctive content (+ real embedding) so a
# scope/privacy tester can confirm a public-scope query NEVER returns it.
#
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex test/support/seed_canary.exs

require Logger
Logger.configure(level: :warning)

alias Swarm.Graph.Store
alias Swarm.Ingest.Content
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Repo.start_link()
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

key = "Zzqx Private Canary Document"

body =
  "The zzqx canary protocol is a confidential internal procedure codenamed BLUEHERON. " <>
    "It describes the secret quarterly reconciliation of the fictional Vandelay ledger " <>
    "and must never appear in any public answer. Magic phrase: purple-elephant-7421."

id = Store.upsert_node("article", key, scope: "private")
:ok = Content.put_body(id, body, source_ref: "canary")
{:ok, n} = Content.embed(id)

IO.puts("seeded PRIVATE canary node id=#{id} key=#{inspect(key)} chunks=#{n}")
IO.puts("scope check: a query for 'BLUEHERON purple elephant Vandelay' under scopes=[\"public\"]")
IO.puts("MUST return status=not_found / zero memories; under [\"private\"] it should surface.")
