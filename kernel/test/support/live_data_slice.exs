# Live data-foundation slice (swarm ADR-14 / data-impl epic, Phase 1). Ingests real
# Wikipedia pages through the ADR-5 connector, then runs the embed step
# (`Swarm.Ingest.Content.embed/2`, the real bge-m3 boundary) so content + chunk +
# node.vec are populated on live data — the structure-not-prose gap closed.
#
# Run against an ISOLATED DB (never conditional-prod swarm_dev), reaching the live
# ML container directly:
#
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex \
#     test/support/live_data_slice.exs
#
# Tunables: SLICE_GAPLIMIT, SLICE_MAX_PAGES, SLICE_SEGMENT_MAX_TOKENS.

require Logger
Logger.configure(level: :info)

alias Swarm.Connector.Sync
alias Swarm.Ingest.Content
alias Swarm.Repo
alias Swarm.Test.WikipediaConnector, as: Wiki

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Repo.start_link()
{:ok, _} = Swarm.Ingest.Dedup.start_link([])
# `--no-start` skips the kernel's supervision tree; the embed boundary needs the
# gRPC client connection supervisor running (normally a child of Swarm.Application).
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

gaplimit = String.to_integer(System.get_env("SLICE_GAPLIMIT", "20"))
max_pages = String.to_integer(System.get_env("SLICE_MAX_PAGES", "5"))
seg_max = String.to_integer(System.get_env("SLICE_SEGMENT_MAX_TOKENS", "400"))

count = fn sql ->
  %{rows: [[n]]} = Repo.query!(sql)
  n
end

IO.puts("== Live data slice (ingest + embed) ==")

IO.puts(
  "db=#{System.get_env("SWARM_DB_NAME", "swarm_dev")} ml=#{System.get_env("SWARM_ML_ADDRESS", "127.0.0.1:50051")}"
)

IO.puts("fetch: gaplimit=#{gaplimit} max_pages=#{max_pages}; segmenter max_tokens=#{seg_max}")

# --- 1. ingest structure + content bodies ---
t0 = System.monotonic_time(:millisecond)
{:ok, report} = Sync.run(Wiki, gaplimit: gaplimit, max_pages: max_pages)
t_ingest = System.monotonic_time(:millisecond) - t0

articles = count.("SELECT count(*) FROM node WHERE type = 'article'")
with_body = count.("SELECT count(*) FROM content")
IO.puts("\n-- ingest --")
IO.puts("pages ingested: #{report.ingested} in #{t_ingest} ms")
IO.puts("article nodes: #{articles}; content rows (bodies): #{with_body}")

# --- 2. embed every content-bearing node that has no chunks yet ---
%{rows: pending} =
  Repo.query!("""
  SELECT c.node_id FROM content c
  WHERE NOT EXISTS (SELECT 1 FROM chunk k WHERE k.node_id = c.node_id)
  """)

IO.puts("\n-- embed (real bge-m3) --")
IO.puts("nodes to embed: #{length(pending)}")

t1 = System.monotonic_time(:millisecond)

{ok, failed} =
  Enum.reduce(pending, {0, 0}, fn [node_id], {ok, failed} ->
    case Content.embed(node_id, max_tokens: seg_max) do
      {:ok, _} ->
        {ok + 1, failed}

      {:error, reason} ->
        IO.puts("  embed failed node #{node_id}: #{inspect(reason)}")
        {ok, failed + 1}
    end
  end)

t_embed = System.monotonic_time(:millisecond) - t1

# --- 3. report population ---
chunk_rows = count.("SELECT count(*) FROM chunk")
vec_nodes = count.("SELECT count(*) FROM node WHERE type = 'article' AND vec IS NOT NULL")

%{rows: [[avg_chunks]]} =
  Repo.query!(
    "SELECT COALESCE(round(avg(c), 2), 0) FROM (SELECT count(*) c FROM chunk GROUP BY node_id) s"
  )

IO.puts("embedded ok: #{ok}, failed: #{failed}, in #{t_embed} ms")
IO.puts("\n-- population (was all-zero before this card) --")
IO.puts("content rows:        #{with_body}")
IO.puts("chunk rows:          #{chunk_rows}  (avg #{avg_chunks}/embedded node)")
IO.puts("nodes with node.vec: #{vec_nodes} of #{articles} article nodes")

if vec_nodes > 0 do
  tput = if t_embed > 0, do: Float.round(ok * 1000 / t_embed, 2), else: 0.0
  IO.puts("embed throughput:    #{tput} nodes/s")
  IO.puts("\nRESULT: content + chunk + node.vec are populated on live data (ADR-14 §2 path lit).")
else
  IO.puts("\nRESULT: NO vectors written — embed boundary unreachable or failing.")
end
