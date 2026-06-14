# Failure Modes & Open Problems

*Companion document to [`swarm_architecture_spec.md`](swarm_architecture_spec.md).*

This document separates two things from the main specification so the positive
architecture is not mixed with negative operational experience:

1. **Failure Modes (anti-patterns)**: classes of failures observed in practice
   in a real implementation of this kind of system.
2. **Open Problems**: questions the reference architecture does not yet answer
   completely.

## Empirical Source

The failure catalog below comes from analysis of a previous agent
implementation (about 11.5k LOC), built iteratively **without a formal
architecture**. Even so, it already contained working versions of roughly half
of the specification domains: a blackboard, hybrid graph+vectors, a tiered
router (gate/cascade), a consilium (panel + judge), a self-model, background
consolidation, symbolic logic, local-first inference, and rare cloud escalation.

The source is valuable in two ways: it produced **proven good patterns** (moved
into ADR-1, 4, 6, 7, and 8 in the main document) and **proven failures** (listed
below). All examples are generalized and de-identified: application-domain
details are omitted; only the engineering class of the problem remains.

> **Decision provenance.** ADR-1, 4, 6, 7, and 8 have empirical roots: they were
> confirmed or falsified by this implementation. ADR-2 (swarm coordination),
> ADR-3 (confidence calculus), and ADR-5 (topology/visibility) are purely
> architectural decisions derived from requirements, without an empirical
> predecessor. That is why the "Resolved Design Questions" table lists them
> without source credit. This is intentional, not an omission.

---

## Failure Modes (Anti-Patterns)

Each row is an observed failure class, not a hypothesis. The "Fix" column points
to the place where the main document addresses the problem.

| # | Anti-pattern | Failure mechanism | Fix |
| --- | --- | --- | --- |
| 1 | **Silent failure as a success-shaped value** | The external-source access layer returned a placeholder string such as `"(lookup unavailable)"` on any failure. The consuming model could not distinguish "empty result" from "source failed" and treated the placeholder as data. | Fail-loud typed errors (Principles; ADR-7) |
| 2 | **Parsing an LLM decision by substring in free text** | Branching such as `decision in output` fired on explanatory text ("this is *not* SIMPLE..."); strict `==` silently fell back on case or punctuation variants such as `"Custom."`. | Structured output / token-anchored parsing (ADR-7; Domain 5) |
| 3 | **Prompt injection into an external action** | Untrusted external text (a record title) entered the prompt without fencing, passed through a panel/judge as a "conclusion", and reached an automated action (public post) without output validation. | Untrusted-data fencing + output validation before action (Domain 12; ADR-7) |
| 4 | **Concurrent storage access without locks** | One embedded connection (SQLite) was shared across async tasks without locks or WAL, causing `database is locked` errors and corruption. The pattern repeated across storage modules. | Transactions + WAL + `busy_timeout` + connection-per-task / writer actor (ADR-1; Domains 1, 14) |
| 5 | **Reinforcement without forgetting (decay)** | The stigmergic trace had a confirmation counter (`seen_count`) but no decay, so traces lived forever; the graph only accumulated and never "breathed". | Reinforcement **and** decay together (Domain 1; Open Problem #1) |
| 6 | **Destroying model disagreement** | The judge collapsed divergent panel opinions into one verdict; inter-model variance ("disagreement as signal") was lost permanently. | Measure variance before synthesis (Domain 4) |
| 7 | **Sequential calls to independent models** | The model panel was queried with an `await` loop instead of true parallelism, producing N-times latency, which is critical with slow judge-class models. | True parallelism (`gather`) (Domain 4) |
| 8 | **Fallback to raw unsynthesized text** | When the judge failed, the system returned a concatenation of raw panel opinions and passed it downstream as a verdict, bypassing the point of synthesis and grounding. | Drop or quarantine with low confidence (Domain 4; ADR-7) |
| 9 | **Naive time stamped as UTC** | An external timestamp in the source's local timezone was stamped as UTC without conversion, creating a persistent multi-hour skew and day-boundary errors. | Timezone-aware conversion at the ingestion boundary (Domain 2) |
| 10 | **Lossy Unicode folding** | Normalization via `casefold` plus stripping `[^a-z0-9_]` reduced non-Latin text (Cyrillic/CJK) to `_`; distinct identifiers collapsed into one, silently losing facts. | NFC without ASCII folding (Domain 2), critical for non-Latin identifiers |
| 11 | **Dry-run implemented at each call site** | The "does not write" guarantee depended on every caller checking locally (`continue` in the service), not on the boundary. One missed guard (bare field access outside `try`) crashed the whole batch. | Dry-run as a boundary property + per-item isolation (Domain 12) |
| 12 | **Dead code diverging from the documented path** | An intended component (predictive difficulty router) was dead; the production path silently collapsed the cascade into "cheapest + most expensive", with middle tiers never executed. | Production path equals documented path; verify-then-climb (Domain 5) |
| 13 | **Boundary enforced by convention** | The invariant "all external access goes through one gateway" was enforced only by code review; nothing structurally prevented bypassing it. | Import-lint contract (Domain 12) |

**Generalization.** Most failures fall into three meta-classes:
(a) **trusting unstructured LLM output** (#2, #3, #6, #8);
(b) **silently swallowing errors** (#1, #9, #10, #11); and
(c) **ignoring concurrency/scale at the storage layer** (#4, #5, #7).
All three are addressed by cross-cutting principles and ADR-1/7 in the main
document.

---

## Open Problems

Unresolved questions the architecture does not yet answer completely. These are
not components; they are research and engineering directions.

1. **Tuning lambda: stigmergic decay vs reinforcement.** Reinforcement
   (`seen_count`) and decay (`exp(-lambda * age)`) are specified in Domain 1,
   but the lambda balance is a separate control parameter. Too low: the graph
   does not forget and anti-pattern #5 returns. Too high: valid patterns are
   lost. Evaporation speed is a key parameter in classic ant-colony systems and
   needs its own control loop, not a constant.
2. **Gate cold start.** An empty graph is covered by onboarding (Domain 17), but
   empty *gate priors* are not. Before enough data accumulates, the gate has no
   empirical bands (ADR-8). It needs manual priors plus a bootstrap-calibration
   procedure that gradually hands decisions over to measurement.
3. **Feedback-loop stability.** Prediction + action + learning form closed
   loops that can oscillate or run away. Rate limits (Domain 12) blunt
   amplitude, but do not damp the dynamics. Formal stability analysis is needed:
   convergence conditions and damping.
4. **Visibility-filter calibration and threat model at scale.** The
   default-deny visibility-scope mechanism is defined (ADR-5), but it is
   security-critical. It needs cross-context privacy-leak regression tests and a
   complete threat model for the filter itself, verified under realistic load.
5. **Detecting independent paths for noisy-OR.** ADR-3 applies
   `1 - product(1 - P_j)` only across independent path groups; within a
   shared-ancestor group it takes `max` (the strongest representative of the
   same evidence). Using `min` here would be wrong: it would penalize having
   several correlated confirmations, dragging confidence down to the weakest
   path, whereas corroboration must never hurt. This avoids double-counting
   evidence from a shared source and silently inflating confidence. The rule is
   defined, but **efficiently detecting shared ancestors/origin sources during
   graph traversal** remains unresolved: naive shared-ancestry checks for every
   path pair are expensive at scale. The system needs a cheap criterion, such as
   provenance tags on edges or lineage fingerprints, or a conservative default
   that treats paths as correlated (collapse with `max`) when independence is
   unproven.

### Round 2 (Reviewer Consilium): Status After Revision

Issues found by independent reviewers (architecture / probabilistic math /
red-team) in the second pass. **Most received a design answer in the ADR
revision; the status and remaining research tail are listed below.** This is an
example of the system's own loop: review -> decision -> residual risk.

1. **Formal semantics for confidence calculus** -> **CLOSED by ADR-3
   (rewritten).** The min+noisy-OR mixture was replaced with the coherent
   probabilistic pair product (AND) / noisy-OR (OR). Source/time are absorbed
   into edge reliability *before* aggregation; `f(seen_count)` is Hill
   saturation (ADR-9). Residual: the output is a heuristic score until
   calibrated (see Round 2 item 2).
2. **Measurement infrastructure** -> **CLOSED by ADR-8/ADR-9.** Frozen held-out
   split (80/20), BH correction + delta tolerance, bootstrap calibration
   (isotonic/Platt, ECE below threshold), and pass/fail gate before calibration.
   Residual: collecting initial external labels (cold start, #2).
3. **Mechanical enforcement of the circularity guard** -> **CLOSED by ADR-4.**
   The provenance check rejects candidates with lineage to `origin:"learned"`;
   correlated axes ("model agrees" + "clean text") count as one. "Internal
   reward" is downgraded to "mitigated, enforced".
4. **Confident-wrong under verify-then-climb** -> **MITIGATED by ADR-7.** The
   judge comes from a different model family to decorrelate blind spots, with a
   judge-accuracy metric on the handle-confidently band (Domain 16). Residual:
   there is no guarantee against correlated errors; this remains a known limit
   of the cascade.
5. **Generalization leakage of derived patterns** -> **CLOSED by ADR-5.** A
   derived node inherits the narrowest parent scope; widening requires
   min-support `k`, a DP-like threshold. Residual: choosing `k` and formal DP
   guarantees remain tuning work.
6. **Fencing leases + singleton idempotency** -> **CLOSED by ADR-1/ADR-2.**
   Monotonic fencing tokens on claim; consolidation is idempotent/fenced;
   liveness alarm. Residual: none.
7. **Visibility filter as a scaling wall** -> **CLOSED by ADR-5.** Scope is
   materialized as an indexed label/edge type, enabling index-level pruning.
   Residual: choosing the decay strategy (lazy-on-read vs batch) is an
   engineering decision.

### Resolved Design Questions

For completeness, these were previously open risks and are now fixed by
decisions in the main document. **"Resolved" means by design.** The *Basis*
column distinguishes empirical roots from purely architectural decisions;
remaining gaps after round-2 revision are in parentheses.

| Question | Decision | Basis | Remaining gap |
| --- | --- | --- | --- |
| Internal reward without an external signal | ADR-4: external truth + gated promotion + enforced circularity guard | empirical | none |
| Concurrent graph writes | ADR-1: transactions + CAS + fencing | empirical | none |
| Worker duplicate work | ADR-2: type partitioning + fenced graph lease | design | none |
| Undefined confidence calculus | ADR-3: product (AND) / noisy-OR (OR), one algebra | design | calibration to data (OP #2) |
| User correction is not first-class | ADR-4: `user_correction` event | empirical | none |
| Topology with multiple users | ADR-5: one graph + materialized visibility scope + min-support | design | choosing `k` / decay strategy (tuning) |
| Embedding migration | ADR-6: namespace stamp + self-healing | empirical | none |
| Undefined LLM I/O contract | ADR-7: structured output + fencing + fail-loud + verify-then-climb | empirical | confident-wrong is a known cascade limit |
| Thresholds "by feel" | ADR-8: empirical derivation + held-out + BH correction | empirical | cold-start label collection (OP #2) |
| Feedback-loop stability | ADR-9: saturating `f` + decay-dominant loop + provenance-independent reinforcement | design | formal stability analysis (OP #3) |
| Visibility-filter scale | ADR-5: materialized indexed scope | design | none |
| Cascade confident-wrong | ADR-7: different-family judge + Domain 16 metric | design | no guarantee against correlated errors |

---

*Negative experience is data too. This failure catalog is valuable precisely
because every item once cost time and trust in the system.*
