# ADR-10: Trace lifecycle — decay-driven GC, bounded weights, re-derivable ρ

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`. This is the **operational realization** of the decay
half of ADR-9 (workspace, stigmergic-loop-stability); it does not change that
decision, it makes traces actually evaporate.

## Status

Accepted (built and validated — see `../design/trace-lifecycle.md`)

## Record Completeness

Complete

## Context

Stigmergic traces must **evaporate** if not reinforced — else the blackboard is
append-only and the O(1) graph degrades to O(N) scans (the operational half of
N1). `Swarm.Graph.Strength` already gives a *saturating* trace (Hill, bounded
`< 1`) with `exp(-ρ·age)` decay (ADR-9), but nothing ever **removed** a trace the
decay had forgotten. The literature is emphatic: the **decay rate ρ is the master
stability knob** (ρ=0 never forgets → saturation; too high erases live signal),
and it is **scale-specific — re-derive it** (the same "bands are nomic-scale"
lesson). Prior art: JavaSpaces leased tuples, MMAS bounded pheromone, ant-colony
evaporation.

## Decision

1. **Decay-driven GC.** `Swarm.Graph.GC.reap/1` deletes edges whose decayed
   strength `saturation(seen_count) · exp(-ρ·age_days)` is below a `:floor` — the
   traces decay has effectively forgotten. One set-based `DELETE`; ρ and S come
   from the tuning inventory (Config). A thin config-gated GenServer runs it on an
   interval (disabled in tests, which call `reap/1` directly).

2. **Bounded above, no min floor.** Hill saturation already bounds strength
   `< 1` (ADR-9) — a re-emitted trace cannot lock in as a permanent attractor.
   Unlike MMAS, there is **no minimum floor**: Swarm *wants* full evaporation so
   GC can reap, rather than keeping a permanent exploration pheromone (a different
   goal than ant-colony optimization).

3. **ρ is re-derivable per corpus scale**, not a magic constant. Procedure: pick a
   target half-life `H` (days after which an un-reinforced trace is GC-eligible) →
   `ρ = ln(2)/H`; choose the reap `:floor` as the strength that separates
   known-stale from live traces (measure the strength distribution). Documented in
   the `GC` moduledoc; ρ lives in `Config` (`:decay, :lambda`).

4. **The other lifecycle halves are tied, not duplicated.** Per-kind TTL is the
   job of **graph zones (T12)** — each zone gets its own TTL/compaction;
   consume-on-read for one-shot coordination traces is the job of **leases (T13)**.
   This ADR owns the decay-driven reap + bounded weights + ρ.

## Consequences

- The working set stays bounded under churn — the saturation bench
  (`kernel/bench/trace_gc.exs`) shows NO-GC retaining ~10000 traces vs WITH-GC
  ~1000 (the reinforced ~10%) over 5 churn rounds. Scan/traversal cost over the
  graph is bounded with it (cost ∝ reachable subgraph, T1).
- `seen_count` reinforcement is bounded (Hill), so GC + decay + saturation together
  give the ADR-9 stability the workspace ADR named but had not operationalized.
- **Durable scheduling deferred.** The GenServer interval is the in-process job;
  an Oban-backed schedule (system architecture §7) is a follow-up — the *policy*
  (decay-driven reap, re-derivable ρ) is fixed, the durable *substrate* is not.

## Alternatives

- **Never reap.** Rejected — the append-only trash fire; O(1) lookups degrade to
  O(N) scans (N1).
- **Reap by a fixed TTL only.** Rejected — a flat age cutoff ignores reinforcement;
  decay-driven reap keeps a much-reinforced-but-old trace and drops a once-seen
  recent one, which is the stigmergic-correct behavior.
- **Keep an MMAS min floor.** Rejected — that preserves a permanent exploration
  pheromone; Swarm's goal is eviction, not exploration, so full evaporation +
  reaping is correct here.
