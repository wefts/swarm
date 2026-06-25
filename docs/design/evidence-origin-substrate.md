---
status: proposed
implements: "workspace ADR-13 (Proposed) — ../../../docs/decisions/0013-evidential-origin.md"
owner: swarm
---

# Spec: Evidence/origin substrate — first-class origin + wired independence defenses

Implementable design for workspace ADR-13. It says *what to build* precisely
enough to implement against; it does **not** authorise building it (that is the
`evidence-origin-substrate` campaign). Extends the ADR-4 graph contract (schema
version bump), reuses the ADR-11 `kind` vocabulary and `Confidence.combine_typed/1`,
and is co-designed with the enrichment reward-gate so both ride one lineage
primitive. Reconciliation with ADR-3/9/11/13/14 is the last section.

Grounding (code, today): `Swarm.Graph.Store.add_edge/5` increments `seen_count`
once per distinct `(edge_id, provenance)` row in `edge_provenance` (text key);
`Swarm.Graph.Traverse` computes `w.conf · e.reliability · decay` with **no**
grouping; `Confidence.combine_typed/1` is defined and has **no production caller**;
schema version is **3**.

## 0. The shape in one picture

```text
  ingest event ──┐
                 │  carries TWO keys:
                 ├── provenance  = emission instance  (one per event; dedup guard)
                 └── origin      = evidential source identity (content-derived; STABLE)

  re-emit same fact ⇒ new provenance, SAME origin   (does not corroborate)
  genuinely independent source ⇒ new provenance, NEW origin (does corroborate)

  seen_count   := count(DISTINCT origin)         not count(DISTINCT provenance)
  reinforce(e) := bounded per-origin ceiling     not unbounded per-event
  traverse     := combine_typed over groups      not naive chain product
```

One rule: **the unit of corroboration is the origin, not the event.** Provenance
still exists and still does its job (idempotent event dedup, the endogenous-loop
guard); origin is the *new* axis that corroboration and reinforcement count on.

## 1. Schema — origin as a first-class reinforcement property

Bump the ADR-4 schema version **3 → 4** (round-trip tested per the ADR-4 policy).

- Add `origin :text` to `edge_provenance` (the existing guard table), NULL only
  for legacy rows. The unique guard stays `(edge_id, provenance)` — origin is an
  attribute of the event, not a new dedup key. A `(edge_id, origin)` index backs
  the distinct-origin count.
- `edge.seen_count` is **redefined** as `count(DISTINCT origin)` over the edge's
  provenance rows (was `count(*)`). Migration recomputes it for existing edges
  (legacy NULL origin ⇒ fall back to provenance identity, so no edge loses count).
- No new evidence-bearing tier; this is an attribute on the existing guard, per
  ADR-14 part 1 ("1 source ≈ 1 origin").

## 2. Reinforcement — count and cap by origin

`Store.add_edge/5` (and `merge_nodes` provenance union) change so that:

- Recording an event writes `(edge_id, provenance, origin)`. `reinforced: true`
  is returned only when the event introduces a **new distinct origin** for the
  edge; a fresh provenance under an *existing* origin is recorded (audit trail)
  but does **not** bump `seen_count`.
- A **per-origin reinforcement ceiling** caps one origin's contribution — the
  strength-dimension mirror of ADR-3's "max within a shared-ancestor group". One
  origin emitting N derivative events cannot push strength past the ceiling. The
  ceiling constant lives in the ADR-8 tuning inventory, never inline.

This closes the immortal-edge hazard (ADR-9 §Consequences): a connector
re-emitting derivatives of one source refreshes `last_seen` but cannot reinforce
past one origin's ceiling.

## 3. Read path — wire `combine_typed` into traversal/retrieval

Give `Confidence.combine_typed/1` its production caller (closes the dead-code
gap):

- Where the read path aggregates multiple contributions into one node/answer
  confidence, group contributions by `(origin, kind)` and feed
  `combine_typed/1`: LLM-generated kinds collapse to one group; each distinct
  external origin is its own independent group (noisy-OR across).
- The single-source `Traverse` chain (one shared-ancestor group → `max`) is
  unchanged in result; the wiring matters at the **fan-in** point where N
  contributions meet — exactly the point a real enrichment worker will populate.
- This is the typed companion to the existing `combine/1`, applied *wherever
  cross-origin corroboration is computed*, per ADR-11 part 2.

## 4. Connector origin contract (boundary, `ports.md`)

The origin key is **derived from source/content identity**, supplied at the
ingest boundary where origin is known:

- Re-ingesting the same fact/source MUST reuse the same origin key; a genuinely
  independent source MUST get a distinct one. `Contract.validate_edge` gains a
  shape check (origin present, non-blank) alongside the existing provenance check.
- This is the cheapest correct cut (push origin determination to the boundary);
  the kernel only *counts and caps* by it. A rule in `ports.md`, enforced at
  ingest.

## 5. Reward-gate control plane (co-designed, same substrate)

The enrichment control plane (`enrichment-reward-gate-control-plane`) rides the
same lineage primitive and is specified here so it is not bolted on:

- **Durable watermark.** A node records what has been enriched and under which
  origin, so re-seeing it does **not** re-pay the ~120 s extraction. Keyed to the
  origin substrate (§1), not a separate ad-hoc table.
- **Worth-it priority computed BEFORE escalation.** A cheap signal (novelty,
  scope, degree, staleness, demand) decides *whether* a node earns the expensive
  extraction — enrichment fires rarely and deliberately (cost-asymmetry pillar).
  This is the scheduler the budget breaker is **not**.
- **Convergence guard by construction.** The spike's loop converged only because
  enrichment output (entities) ≠ input (articles). Encode a generation/zone guard
  (ADR-11 typing): the worker enriches `observation`/article zones and never its
  own `claim` output, so the worker→graph→worker loop is provably bounded once an
  entity→entity inference worker exists.

## 6. Sequencing & coupling (load-bearing)

- **Entity-resolution soft-match (Y) is BLOCKED on §1–§3.** Soft-merging the 24
  near-duplicate entity pairs *before* origin accounting manufactures the
  correlated-evidence inflation (two spellings of one source merge → one origin
  counted twice as if two). Soft-match lands only after origin is first-class.
- **No real enrichment worker ships without §5's gate.** Nothing enriches now
  (the spike wiped); this is a build-time rule, not an emergency.
- **Lineage clustering of distinct-but-correlated origins is deferred** (ADR-13
  first-cut boundary): structural origin-keying + per-origin cap ship now;
  semantic origin clustering (region-based BP) waits for multi-origin
  corroboration at scale (traversal is flat 0.8–2.6 ms today).

## 7. Done-conditions (what real signal proves it)

- Schema v3→v4 migration applies and round-trips on `swarm_slice`; `seen_count`
  recompute leaves no edge with a lower count than before.
- A **traversal/confidence test** proves: N edges that are derivatives of one
  origin (or N co-located `claim` contributions) yield the **same** confidence as
  one; two independent **observations** yield the noisy-OR (0.8, 0.8 → 0.96).
  `combine_typed/1` gains a production caller (grep proves it is no longer dead).
- A **reinforcement test** proves one origin emitting N derivative events cannot
  push `seen_count`/strength past the per-origin ceiling.
- `mix` green, `mix format` + `credo` clean (`docs/standards/verification.md`),
  and an independent critic on the model choice.

## 8. Reconciliation with the canon

- **ADR-3 (confidence calculus).** §3 wires the confidence-side independence rule
  into the read path; the deferred large-scale grouping (region-based BP) stays
  deferred (§6) — this does not change ADR-3, it operationalizes its read-path
  consequence.
- **ADR-9 workspace (strength).** §1–§2 decide its open Consequence (origin vs
  emission instance; per-origin cap). The Hill-saturation + decay mitigation
  (`Swarm.Graph.Strength`) is unchanged; origin counting is the *correction* it
  was missing.
- **ADR-11 (zones/claim typing).** §3 makes `combine_typed` live; §5's zone guard
  uses the `kind` vocabulary. Reward-gated persistence (read-time `reward >= 0`)
  is unchanged.
- **ADR-13 swarm (entity resolution).** §6 records the blocker direction
  explicitly; merge already unions provenance — it must union **origin** so a
  merge cannot collapse two origins into over-corroboration.
- **ADR-14 (data/memory model).** Origin is the lineage axis ADR-14 part 1
  reserved ("1 source ≈ 1 origin"); enrichment (§5) is the reward-gated layer of
  ADR-14 part 6 made real.
