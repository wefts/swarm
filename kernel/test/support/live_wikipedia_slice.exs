# Live first vertical slice (Phase E2): ingest REAL public Wikipedia pages through
# the swarm ADR-5 connector contract into the live graph, then measure the
# architect-consilium's predicted failure modes on real data.
#
# Run (against the same Postgres the hive kernel uses — swarm_dev), WITHOUT
# starting a second kernel (no core_api port clash, no competing tailer/GC):
#
#   MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex \
#     test/support/live_wikipedia_slice.exs
#
# Tunables via env: SLICE_GAPLIMIT (pages/API call), SLICE_MAX_PAGES (API pages).

alias Swarm.Connector.Sync
alias Swarm.Repo
alias Swarm.Test.WikipediaConnector, as: Wiki

# --no-start skips dependency apps; bring up just what Ingest needs (the DB stack
# + the dedup ETS owner), NOT a second kernel (no core_api/tailer/GC/stagnation).
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Repo.start_link()
{:ok, _} = Swarm.Ingest.Dedup.start_link([])

gaplimit = String.to_integer(System.get_env("SLICE_GAPLIMIT", "20"))
max_pages = String.to_integer(System.get_env("SLICE_MAX_PAGES", "5"))

count = fn sql ->
  %{rows: [[n]]} = Repo.query!(sql)
  n
end

articles0 = count.("SELECT count(*) FROM node WHERE type = 'article'")
edges0 = count.("SELECT count(*) FROM edge WHERE type = 'links_to'")

IO.puts("== Live Wikipedia slice ==")
IO.puts("before: #{articles0} article nodes, #{edges0} links_to edges")
IO.puts("fetching: gaplimit=#{gaplimit} max_pages=#{max_pages} (~#{gaplimit * max_pages} pages)")

t0 = System.monotonic_time(:millisecond)
{:ok, report} = Sync.run(Wiki, gaplimit: gaplimit, max_pages: max_pages)
elapsed = System.monotonic_time(:millisecond) - t0

articles1 = count.("SELECT count(*) FROM node WHERE type = 'article'")
edges1 = count.("SELECT count(*) FROM edge WHERE type = 'links_to'")

dn = articles1 - articles0
de = edges1 - edges0

IO.puts("\n-- Sync report --")
IO.puts(inspect(report, pretty: true))

IO.puts("\n-- Graph delta --")
IO.puts("article nodes: #{articles0} -> #{articles1}  (+#{dn})")
IO.puts("links_to edges: #{edges0} -> #{edges1}  (+#{de})")

IO.puts("\n-- Risk #4: Postgres write throughput --")
IO.puts("wall: #{elapsed} ms for #{report.ingested} pages")

tput_n = if elapsed > 0, do: Float.round(dn * 1000 / elapsed, 1), else: 0.0
tput_e = if elapsed > 0, do: Float.round(de * 1000 / elapsed, 1), else: 0.0
IO.puts("throughput: #{tput_n} nodes/s, #{tput_e} edges/s")

# Risk #1: entity fragmentation. Our canonical_title/1 already folds underscores,
# whitespace, anchors and first-letter case. A genuine fragmentation instance is
# a set of DISTINCT keys that collapse to the same case-insensitive form but were
# NOT merged — i.e. the substrate holds >1 node for what is plausibly one entity.
IO.puts("\n-- Risk #1: entity fragmentation probe --")

%{rows: frag_rows} =
  Repo.query!("""
  SELECT lower(key) AS folded, count(*) AS n, array_agg(key) AS variants
  FROM node WHERE type = 'article'
  GROUP BY lower(key) HAVING count(*) > 1
  ORDER BY n DESC LIMIT 15
  """)

if frag_rows == [] do
  IO.puts("no case-insensitive key collisions among article nodes (canonicalisation held)")
else
  IO.puts(
    "#{length(frag_rows)} case-folded collision group(s) — fragmentation our canonicaliser missed:"
  )

  for [folded, n, variants] <- frag_rows, do: IO.puts("  #{folded}: #{n} -> #{inspect(variants)}")
end

# Unresolved link targets: article nodes that are ONLY ever a link destination,
# never ingested as their own page. Expected to dominate (we fetched few pages,
# they link out widely) — this is reach, not fragmentation, but worth the number.
stub_only =
  count.("""
  SELECT count(*) FROM node n
  WHERE n.type = 'article'
    AND NOT EXISTS (SELECT 1 FROM edge e WHERE e.src = n.id AND e.type = 'links_to')
  """)

IO.puts("\n-- Reach --")
IO.puts("link-target-only nodes (never fetched as a page): #{stub_only} of #{articles1}")

# A few high-out-degree pages to drive the ask step.
%{rows: hubs} =
  Repo.query!("""
  SELECT n.key, count(*) AS out_degree
  FROM node n JOIN edge e ON e.src = n.id AND e.type = 'links_to'
  WHERE n.type = 'article'
  GROUP BY n.key ORDER BY out_degree DESC LIMIT 8
  """)

IO.puts("\n-- Sample fetched pages (highest out-degree) — use these to ask --")
for [key, deg] <- hubs, do: IO.puts("  #{key} (#{deg} links)")
