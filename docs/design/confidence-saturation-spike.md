---
status: measured
implements: "swarm ADR-3 (Proposed) — ../decisions/0003-confidence-traversal-bounding.md"
owner: swarm
---

# Spec: Confidence saturation spike (T1)

A measurement spike, not a feature. It answers one question from the roadmap
(board T1, closes risk N1): on a saturated graph, does computing confidence
**collapse**, and is the cost in **traversal** (the recursive-CTE path enumeration
in `Swarm.Graph.Traverse`) or in **independence grouping** (ADR-3 step 2, the named
`O(hard)` open problem in `../../../docs/architecture/confidence-calculus.md`)?

The seam decision it produced: swarm ADR-3,
`../decisions/0003-confidence-traversal-bounding.md`.

## The bench

`../../kernel/bench/confidence_saturation.exs`. Reproducible, committed. Run it
(Repo only — the full app's gRPC port clashes with a running kernel) against a
throwaway DB:

```bash
cd swarm/kernel
SWARM_DB_NAME=swarm_bench SWARM_DB_HOST=localhost \
  mix run --no-start bench/confidence_saturation.exs
```

It TRUNCATEs the graph tables per scenario — never point it at real data.

### Method

A synthetic **layered DAG**: `layers` layers of `width` nodes; each node links to
`fanout` random nodes in the next layer. Two axes are varied **independently** so
the collapse can be attributed:

- **SIZE axis** — many edges, `fanout=2` (low path-overlap): pure graph scaling.
- **DENSITY axis** — modest edges, high `fanout`/`depth`: path count explodes
  (`fanout^depth`) while edge count stays small. The adversarial case.

Methodology guards (each found and fixed during the spike):

- **`ANALYZE` after the bulk load.** Without fresh stats the planner sees
  `reltuples≈0` and seq-scans the recursive join — a 2.3 s artifact at 1e6 edges
  that vanished once stats were refreshed. The `edge.src`/`edge.dst` indexes
  already exist.
- **`O(1)` confidence lookup in grouping.** A list `Enum.at` made the grouping
  prototype `O(P²)` and inflated its cost ~250×; a tuple fixed it to the honest
  `~O(P)`.
- **Per-measurement `statement_timeout`** (20 s, via `SET LOCAL`) so a runaway
  query aborts cleanly; generators run uncapped. Hitting the cap **is** a result
  (the query collapsed).
- A separate **multi-origin grouping bench** isolates ADR-3 step 2 from the
  single-source DAG (where all paths trivially share the start → one group).

## Results

Budget 1000 ms/query; DB cap 20000 ms. (Representative run, GB10 / hive-postgres.)

### Traversal + grouping vs size and density

`walk rows` (≈ `paths@sink`) is the path-multiplicity proxy and the memory story;
it is a stripped `count(*)` CTE, not the timed `Traverse.traverse` query (which
also computes per-hop decay + final aggregation), so it tracks path *count*, not
the timed query's per-row cost. `groups` is structurally 1–2 here because the walk
is single-source (all paths share the start) — grouping is isolated separately
below.

| scenario | edges | depth | traverse ms | walk rows | paths@sink | group ms | groups | knee |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| size ~1e3 f2 d5 | 992 | 5 | 5.1 | 61 | 30 | 0.0 | 1 | ok |
| size ~1e4 f2 d5 | 9992 | 5 | 4.1 | 63 | 32 | 0.0 | 2 | ok |
| size ~1e5 f2 d5 | 99995 | 5 | 7.7 | 63 | 32 | 0.0 | 2 | ok |
| size ~1e6 f2 d5 | 999996 | 5 | 2.5 | 63 | 32 | 0.0 | 2 | ok |
| dense ~8e3 f4 d7 | 27959 | 7 | 29.2 | 21617 | 16201 | 14.6 | 1 | ok |
| dense ~5e4 f6 d7 | 41899 | 7 | 331.7 | 331722 | 276228 | 224.6 | 1 | ok |
| dense ~9e4 f8 d9 | 71755 | 9 | >cap | >cap | — | — | — | TRAVERSAL |
| dense ~1e5 f12 d11 | 131316 | 11 | >cap | >cap | — | — | — | TRAVERSAL |

### Independence grouping in isolation (multi-origin, `P` paths)

This bench feeds `group_and_combine` a multi-origin path set and varies pool vs
`P·len` to sweep the **group count** from one fused component to ~`P` independent
groups — the regime that actually stresses the partition and the cross-group
noisy-OR fold (the single-source DAG above cannot, by construction).

| paths P | origins | len | pool | group+combine ms | groups |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 000 | 50 | 5 | 2e2 | 111.3 | 1 |
| 100 000 | 1 000 | 2 | 5e6 | 283.4 | 95 929 |
| 100 000 | 10 000 | 1 | 5e7 | 212.9 | 99 889 |
| 300 000 | 10 000 | 1 | 5e7 | 714.4 | 299 132 |
| 300 000 | 50 000 | 1 | 2e8 | 708.9 | 299 761 |

## Findings

1. **Single-source traversal is independent of graph size.** 1e3 → 1e6 edges:
   ~2–7 ms, `walk rows` constant at ~63. Cost tracks the *reachable subtree*, not
   the table. The earlier 2.3 s at 1e6 was a stale-stats artifact, not intrinsic.
2. **Path multiplicity (`fanout^depth`) is the wall.** The recursive CTE
   materializes **one row per path** (`walk rows` ≈ `paths`). By fanout 8 /
   depth 9 — only ~72k edges — it cannot enumerate within 20 s. The collapse is
   **traversal**, and it happens *before* grouping runs.
3. **Independence grouping is not the bottleneck — across the whole group-count
   regime.** `group_and_combine` is ~`O(P)` whether the path set fuses into **one**
   group (111 ms / 100k paths) or splinters into **~`P` independent** groups
   (714 ms / 300k paths / 299k groups — the worst case for the cross-group noisy-OR
   fold). Group count barely moves the cost; `P` does. The expense is *producing*
   `P` (traversal), not partitioning or combining it.
4. **The enumeration is redundant for the current output.** `Traverse` returns
   `max(conf)` per node (≤ reachable node count); for single-source aggregation
   the per-path intermediate is provably wasteful (`walk rows` 331k → output ≤ a
   few k nodes).

## Decision (recorded in swarm ADR-3)

- Traversal becomes **node-bounded** (best-confidence-per-node relaxation), not
  path-bounded — same ADR-3 result, `O(max_depth·reachable_edges)`.
- Confidence is **best-effort above a frontier budget** (flagged, not unbounded).
- Independence grouping stays **bounded and off the critical path**; region-based
  BP remains a deferred open problem (it is cheap relative to enumeration).

The relaxation rewrite of `Traverse` is a **follow-up task**, not part of this
spike. Until it lands, callers must keep `max_depth` small (the existing,
now-load-bearing moduledoc caveat).

## Limitations (honest scope)

- **Wall-time, not bytes.** `walk rows` is reported as the memory proxy (one row
  per path materialized in the CTE); resident bytes per query were not measured.
  The qualitative memory story — per-path materialization explodes with `P` — is
  clear; an RSS/`work_mem` profile is left to the relaxation-rewrite follow-up.
- **Size-axis times live near the cache-noise floor** (2–8 ms). The claim is
  qualitative ("cost tracks the reachable subtree, not the table"), supported by
  the constant `walk rows`; it is not a precise quantitative curve, and cold-cache
  ordering / Postgres JIT on the dense plans were not isolated.
- **Three CTE variants** (timed traverse, `walk` count, path enumeration) back
  different columns; they share the same recursive structure, so the
  enumeration-is-the-wall attribution holds in shape, but the columns are not the
  same query.
- Verified on one host (GB10 / `hive-postgres`); absolute ms are not portable, the
  asymptotics are.

## Acceptance

- Reproducible committed bench, query cost vs size/density, collapse knee named
  with numbers. ✓
- A written decision (swarm ADR-3): node-bounded traversal + best-effort budget,
  grouping deferred. ✓
- `mix test` green (72/0); bench runs by hand with the documented command. ✓
