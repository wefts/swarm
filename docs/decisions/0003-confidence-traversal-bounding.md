# ADR-3: Confidence traversal is node-bounded, best-effort above a budget

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`. This is the kernel-implementation seam under the
locked confidence calculus (ADR-3 workspace); it does not change the algebra.

## Status

Proposed (decided by the T1 saturation spike; implementation is a follow-up —
see `../design/confidence-saturation-spike.md` and the board card)

## Record Completeness

Complete

## Context

`docs/architecture/confidence-calculus.md` (ADR-3 workspace) names
**path-independence detection at scale** as an open, `O(hard)` problem, and warns
that attaching hostile high-volume sources grows the graph fast. The risk the T1
spike set out to measure: does computing confidence **collapse** on a saturated
graph long before any token limit matters — and is the cost in **traversal** (the
recursive-CTE path enumeration in `Swarm.Graph.Traverse`) or in **independence
grouping** (ADR-3 step 2)?

The spike benchmarked `Traverse`/`Confidence` against synthetic layered DAGs,
separating two axes — raw graph **size** (low path-overlap) and path-explosion
**density** (`fanout^depth`) — plus an isolated multi-origin grouping bench.
Numbers and method: `../design/confidence-saturation-spike.md`. The findings:

- **Single-source traversal cost is independent of total graph size.** 1e3 → 1e6
  edges traverse in ~2–7 ms; the cost tracks the *reachable subtree*, not the
  table (the `edge.src` index + fresh stats already handle size).
- **Path multiplicity is the wall.** The recursive CTE materializes **one row per
  path**, and paths grow `fanout^depth`. By fanout 8 / depth 9 (only ~72k edges)
  the walk cannot even enumerate within a 20 s cap. The collapse is **traversal**,
  and it happens *before* grouping ever runs.
- **Independence grouping is not the bottleneck.** Given a path set of size `P`,
  ADR-3 step 2 (union-find partition + combine) is ~`O(P)` — sub-second even at
  300k paths in the maximal-overlap worst case. The expense is *producing* `P`,
  not grouping it.
- **The per-path enumeration is redundant for the current output.** `Traverse`
  aggregates to `max(conf)` per node (≤ reachable node count). For single-source
  aggregation, all paths to a node share the start (one shared-ancestor group →
  `max`), so enumerating every path to then take a max is provably wasteful.

## Decision

1. **Traversal is node-bounded, not path-bounded.** Replace the per-path recursive
   CTE with a **best-confidence-per-node relaxation** (keep each node's maximum
   incoming confidence, relaxed outward to `max_depth`). For single-source
   aggregation this returns the identical ADR-3 result (within-shared-ancestor
   `max`) at `O(max_depth · reachable_edges)` instead of `O(fanout^depth)`. This
   removes the collapse. (The `Traverse` moduledoc already flags "switch to a
   visited-set BFS" as the caveat; this ADR commits to it.)
2. **Confidence is best-effort above a frontier budget.** Keep the `max_depth`
   cap and add a reachable-frontier / edge-visit budget. Beyond it, return a
   best-effort result **flagged as truncated** rather than running unbounded —
   the explicit "confidence is best-effort above N" contract.
3. **Independence grouping stays bounded and off the critical path.** Cross-origin
   noisy-OR (`Confidence.combine`) operates only on a **bounded set of independent
   origin groups**, never on raw enumerated paths. Region-based / loop-corrected
   belief propagation (the principled general solution) remains a documented open
   problem, deferred until multi-origin corroboration at scale is actually built —
   the spike shows grouping is cheap relative to enumeration, so it is not the
   thing to optimize first.

## Consequences

- The decision is recorded now; the **relaxation rewrite of `Traverse` is a
  follow-up task** (a board card; a natural companion to T2's graph-integrity
  work). Until it lands, the existing CTE is correct but callers MUST keep
  `max_depth` small — the documented caveat, now load-bearing.
- The locked ADR-3 (workspace) algebra is unchanged: same AND/OR/within-group-max
  result, computed by a bounded mechanism.
- Hostile high-volume ingest (T3/T4) no longer threatens to paralyze confidence
  through depth×fanout, provided the budget cap is enforced.
- A truncated/best-effort flag becomes part of the confidence result contract
  (ties into T6 answer-result algebra).

## Alternatives

- **Raise `max_depth` (or the cap) blindly.** Rejected — the cost is
  `fanout^depth`; raising the cap accelerates the collapse. The moduledoc warns
  against exactly this.
- **Precompute independence-group labels.** Deferred — premature. Grouping is not
  the bottleneck; labeling optimizes the cheap step while the expensive one
  (enumeration) is what collapses.
- **Adopt region-based BP now.** Rejected — it solves a problem (large-scale
  multi-origin independence partitioning) that is not yet on the critical path;
  node-bounded relaxation fixes the measured collapse without it.
