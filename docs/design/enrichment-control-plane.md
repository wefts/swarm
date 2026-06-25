---
status: proposed
implements: "workspace ADR-13 (Proposed) §Decision.4 — ../../../docs/decisions/0013-evidential-origin.md"
owner: swarm
---

# Spec: Enrichment reward-gate control plane

Implementable design for the enrichment control plane (workspace ADR-13
§Decision.4, EOS-4). It says *what to build* precisely enough to implement
against, and it rides the **same origin/lineage substrate** as EOS-1..3 — the
control plane and the evidence accounting share one metadata primitive, by design.

**Build gate (load-bearing).** This is a **design**, not shipped code. **Nothing
enriches today** (the cognitive-activation spike was wiped), so there is no worker
to gate yet. Shipping watermark/priority *tables and code before the enrichment
worker exists would be the very dead-code anti-pattern ADR-13 was created to fix*
(`combine_typed` sat uncalled; we will not repeat it). The build lands **with**
the enrichment-worker epic, not before — and that worker MUST NOT ship without
this gate (ADR-13 §Decision.4 guardrail). This doc is what that epic builds to.

## 0. Why a control plane (not a budget fuse)

The spike wired enrichment as a blanket `content_added` reactor: it reprocessed
the whole outbox backlog — **564 triggers from one seed** — and only the
per-escalation **budget backstop** stopped it (556 refused). The council's verdict
stands: **a budget breaker is an emergency fuse, not a scheduler.** Blanket
on-write triggers perpetually hammer the breaker and starve legitimate work. The
missing piece is a scheduler that makes enrichment **rare, deliberate, and
worth-it** — the "reward-gated" the concept always named but never had. Enrichment
is the cost-asymmetry pillar in the flesh (~120 s/source); it must fire on the few
nodes that earn it, never continuously.

## 1. The three pieces (one substrate)

### 1a. Durable watermark — "what has been enriched, under which origin"

- A node records that it was enriched, **keyed to the origin substrate** (EOS-1)
  **and content-sensitive + invalidatable** (council, codex):
  `(node_id, origin, source_revision | content_hash, extraction_policy_version,
  model, generation, state)` where `state ∈ {fresh, stale, retry, error}` — not a
  bare "done" flag. `(node_id, origin)` alone must **not** mean "never enrich
  again": a key that ignored content revision would suppress re-extraction when the
  *same origin* corrects or expands its content, or when the extraction policy/model
  improves. So a re-enrich is triggered when ANY of: a **new independent origin**
  arrives, the **content hash/revision changes** for an existing origin, or the
  **policy/model generation** is bumped (mass re-enrich). Re-seeing the *same*
  `(node_id, origin, content_hash, policy, model)` in `fresh` state does **not**
  re-pay the ~120 s extraction.
- Because the watermark is origin-keyed, a *new independent origin* asserting the
  same node is genuinely new evidence (legitimate re-enrich), while a mere
  derivative (same origin, same content) is not — the origin distinction EOS-1
  makes for reinforcement, reused here for scheduling.

### 1b. Worth-it priority — computed BEFORE escalation

- A **cheap** signal (no LLM) scores whether a node earns the expensive extraction,
  evaluated *before* any model call:
  - **novelty** — un-watermarked, or watermarked only by now-stale origins;
  - **scope/centrality** — degree / hub-ness (a highly-referenced node is worth
    more than a leaf);
  - **staleness** — decayed since last enrichment;
  - **demand** — retrieval/traversal hit-count (a node people actually ask about);
  - **confidence-criticality** — on a low-corroboration path that answers depend on.
- Only nodes above a threshold (ADR-8 tuning inventory) enter the enrichment queue,
  worth-it-first. The budget backstop remains as the *fuse* beneath the scheduler,
  never the scheduler itself.
- **Priority reads the watermark (council, gemma):** novelty is computed *against*
  §1a — a node whose `(origin, content_hash, policy, model)` is already `fresh`
  scores ~0 novelty (no re-pay), so the scheduler cannot be gamed into re-doing
  covered work; novelty rises only on a new origin, changed content, or a bumped
  policy/model generation. Watermark and priority are thus coupled, not independent.

### 1c. Convergence / zone guard — bounded by construction

- The spike's loop converged **only because** enrichment output (entities) ≠ input
  (articles) — type-disjointness, brittle once an entity→entity inference worker
  exists. Encode the guard explicitly (ADR-11 zones): the worker enriches
  `observation`/article zones and **never its own `claim`/`derived` output**, and
  each enriched trace carries a **generation** counter; a node may be enriched at
  most once per generation, and generation-N output is not eligible input for
  generation-N enrichment. So the worker→graph→worker loop is **provably bounded**,
  not bounded-by-accident.

## 2. How it composes with EOS-1..3

- **Watermark ⟂ reinforcement:** both key on `origin`. The watermark answers "did
  we already pay to extract from this origin?"; reinforcement (EOS-1) answers "how
  many distinct origins attest this edge?". One primitive, two consumers.
- **Priority reads corroboration (EOS-2):** confidence-criticality uses
  `Swarm.Graph.Corroboration` — a low-corroboration node on a depended-upon path is
  worth enriching; a well-corroborated one is not.
- **No new origin semantics:** the control plane introduces scheduling, not new
  evidence rules; the evidence accounting stays entirely in EOS-1..3.

## 3. Done-conditions (for the future enrichment-worker build)

- A node already watermarked for origin O is **not** re-enriched on re-seeing O
  (test: re-deliver ⇒ zero LLM calls), but **is** eligible when a new independent
  origin arrives.
- The priority signal is computed without any model call and orders the queue;
  below-threshold nodes never escalate (test on a synthetic graph).
- The zone/generation guard makes the worker→graph→worker loop terminate with the
  guard present and demonstrably *not* terminate with it removed (the spike's
  failure mode), proving the guard is load-bearing.
- The budget fuse still bounds a pathological run, but the scheduler keeps the fuse
  from ever being the primary control (observable: fuse-refusal rate ≈ 0 in normal
  operation).

## 4. Out of scope (deferred, named)

- The enrichment worker itself (extraction prompt, model routing, claim writing) —
  its own epic; this is only its gate.
- Weighted per-origin contributions and lineage clustering of correlated origin
  keys — the ADR-13 first-cut boundary (evidence-origin-substrate spec §6).
