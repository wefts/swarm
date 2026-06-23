# ADR-11: Graph zones + claim/observation typing + reward-gated persistence (N3)

Repo-local to `swarm/`. Extends the ADR-4 graph-integrity contract (bumps the
schema version 1→2). Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Accepted (built and validated — see `../design/graph-zones.md`)

## Record Completeness

Complete

## Context

Stigmergy + external-only reward removes the largest MAST failure class
(self-grading) and the N² message blowup — but it **relocates error cascades into
the graph** (N3): a wrong or hallucinated trace becomes the next worker's *ground
truth*, reinforces across workers, and corrupts downstream answers. The defenses
must be structural: an LLM claim must never be treated as independent evidence,
and reward must gate trace **persistence**, not just whether it was appended.

## Decision

1. **Graph zones / tuple-classes.** `node.kind` is the trace's class —
   `observation` (external evidence), `claim` (LLM-generated), and lifecycle kinds
   (`hypothesis`, `coordination`, `lease`, `derived`, `presentation`,
   `durable_fact`). A closed vocabulary, validated by the contract (changeset) and
   a DB `CHECK` (defense-in-depth), each kind free to carry its own TTL/compaction.
   This **extends ADR-4** and bumps the schema version to **2**.

2. **A generated trace is never independent corroboration.**
   `Confidence.combine_typed/1` collapses **all LLM-generated kinds**
   (`claim`/`hypothesis`/`derived`) into one group (max within), while each
   external kind (`observation`/`durable_fact`) is its own independent group
   (noisy-OR across). So three generated contributions of 0.8 yield 0.8, but two
   independent observations of 0.8 yield 0.96 — **a hallucination cannot inflate
   confidence by repetition** (Knowledge-Vault / NELL practice). This is the typed
   sibling of `combine/1`, applied **wherever cross-origin corroboration is
   computed**. The single-source `Traverse` path is one shared-ancestor group
   (`max`) and does not reach the independence question; large-scale multi-origin
   grouping is the deferred open problem of ADR-3 (workspace) / the T1 spike — so
   `combine_typed` is the *ready contract* for that path, not an after-the-fact
   patch (it is no more "uncalled" than `combine/1` itself, which the same
   deferral keeps off the single-source hot path).

3. **Reward-gated persistence, enforced at READ time.** `edge.reward` carries
   external ground-truth; `Store.set_reward/2` applies it. A refuted trace
   (`reward < 0`) is **excluded from traversal immediately** —
   `Swarm.Graph.Traverse` joins `… AND e.reward >= 0`, so a refuted trace stops
   being ground for the next worker the instant it is refuted, **not** only after
   the next GC cycle. `Swarm.Graph.GC` then *reaps* it (T11) regardless of
   strength. `reward ≥ 0` persists on the normal decay schedule.

## Consequences

- The graph error-cascade (N3) has a structural defense: claims don't corroborate
  themselves into false confidence, and a refuted trace is evicted, not decayed
  slowly.
- Per-kind lifecycle is now expressible (the `kind` field is the hook for
  per-zone TTL/compaction; T11's GC + this typing compose).
- **Schema version 2**, round-trip tested: a node written without `kind` reads
  back the `observation` default — the first real vN→vN+1 round-trip the ADR-4
  policy promised (it was untestable at v1).
- The reward path is the coupling external truth → persistence; without a reward a
  trace is neither confirmed nor refuted (it just decays).

## Alternatives

- **Count every supporting path as independent.** Rejected — that is the N3
  cascade: co-located LLM claims inflate confidence and a hallucination becomes
  "fact". Claims collapse to one group.
- **Reward gates only appending, not persistence.** Rejected — a refuted trace
  would linger as ground for the next worker; reward must gate decay/eviction.
- **No claim/observation typing.** Rejected — without it the calculus cannot tell
  agent chatter from external evidence, and the largest new-paradigm risk is open.
