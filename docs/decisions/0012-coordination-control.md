# ADR-12: Coordination control — pattern-match subscriptions + stagnation monitor

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`. Deepens the coordination of ADR-2 (workspace).

## Status

Accepted (built and validated — see `../design/coordination-control.md`)

## Record Completeness

Complete

## Context

Pure stigmergy's named failure (every blackboard/tuple-space system hit it) is the
**control problem**: *who* reacts to *which* trace, and *when*. Two concrete
hazards: (1) graph-wide polling to find work blows up (the other half of N1); (2)
the **bystander-effect deadlock** — a trace that no worker's trigger matches stalls
**forever, silently** (AutoGen's chronic failure). The stigmergy `Dispatch`
(ADR-2) already routes by change kind, but a row matching *no* subscription was a
silent no-op — the bystander case.

## Decision

1. **Pattern-match subscriptions (routing, no scanning).** Workers subscribe to
   the change kinds they handle (`Swarm.Stigmergy.Dispatch.subscribe/3`); the
   tailer routes each consumed row to the per-`target_key` ordered lane, invoking
   only interested handlers. **No worker scans the whole graph** — the kernel
   routes only matching traces. (Subscription is by change kind today; richer
   typed node/edge target predicates are a follow-up.)

2. **Stagnation monitor (the bystander fix).** `Swarm.Coordination.Stagnation`,
   recording **deduped** on `(reason, ref)` so a recurrence never floods:
   - a dispatched row whose change kind matches **no subscription** is surfaced
     **once** (`record_unmatched/1` → `stagnant`, logged) — `Dispatch` calls it
     when the handler set is empty; a high-frequency unhandled kind yields a single
     row, not one per write;
   - `scan_stalls/1` finds claimable `coordination` traces with no `claimed_by`
     older than a TTL (a **stalled claim**) and records each (deduped per node). A
     **config-gated watchdog** (`Swarm.Coordination.Stagnation` in the supervision
     tree, `:swarm, :stagnation`) runs it on an interval — surfacing is
     operational, not only on-demand.
   Inspectable (`recent/1`, `count/0`) so a human / fallback escalation acts.

   **Where the "below-gate-threshold" hazard lands in Swarm.** A below-threshold
   *query* is not abandoned — the gate routes it to `:escalate` (the consilium),
   so it is handled, not stalled. The genuinely-abandoned trace is a graph trace
   no worker reacts to: an **unhandled change kind** (deduped surfaced) or an
   **unclaimed coordination trace** (watchdog) — both caught here. (Honest note:
   "escalated, not stalled" is a *coordination-layer* property — the gate made a
   decision; whether the consilium then fully acts is a separate concern, and the
   escalation target is itself still maturing. T13 guarantees the trace is not
   *silently dropped at the coordination layer*, not that every escalation is
   answered end-to-end.)

## Consequences

- The bystander deadlock is closed: an unmatched trace is recorded + logged, never
  a silent stall; a stalled claim is surfaced by the scan.
- No full-graph polling — routing is by subscription (the N1 control half).
- A standing operational signal: a growing `stagnant` count means traces are
  arriving that no worker handles (a missing subscription / a gate-threshold gap),
  which is exactly the condition to alert on.

## Alternatives

- **Graph-wide polling to find work.** Rejected — O(scan) per worker, the N1
  blowup; subscription routing touches only matching rows.
- **Silently drop an unmatched trace.** Rejected — that *is* the bystander
  deadlock; the monitor surfaces it.
- **Build the MetaGPT-style explicit task state machine now.** Deferred (the
  card's optional item) — the subscription + stagnation pair addresses the named
  hazards; an explicit `Drafted→Critiqued→Approved` SOP is a later refinement.
