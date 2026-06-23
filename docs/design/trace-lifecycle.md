---
status: built
implements: "swarm ADR-10 (Accepted) — ../decisions/0010-trace-lifecycle-gc.md"
owner: swarm
---

# Spec: Trace lifecycle — decay-driven GC (T11)

How stigmergic traces evaporate so the graph stays O(1). Implements swarm ADR-10
(the operational half of ADR-9 workspace).

## Mechanism — `Swarm.Graph.GC`

- `reap(opts)` — one `DELETE` of edges whose decayed strength
  `ln(1+seen_count)/(ln(1+seen_count)+S) · exp(-ρ·age_days)` is below `:floor`
  (default 0.05). Returns the count reaped. ρ = `Config.decay_lambda`,
  S = `Config.saturation_s`.
- `saturation/0` — working-set size `%{edges, nodes}` (the metric that makes
  saturation observable).
- A config-gated GenServer (`:swarm, :gc, enabled/interval_ms/floor`) reaps on an
  interval; disabled in tests, which call `reap/1` directly.

## Bounded weights

Hill saturation (`Strength`, ADR-9) bounds strength `< 1` — re-emission saturates,
so a trace can't become a permanent attractor. **No min floor** (unlike MMAS):
full evaporation is wanted so GC can reap.

## ρ — the master knob, re-derived per scale

ρ (`Config.decay_lambda`) is the `exp(-ρ·age_days)` rate. Procedure:

1. Pick a target half-life `H` (days after which an un-reinforced trace should be
   GC-eligible) → `ρ = ln(2) / H`.
2. Choose `:floor` as the decayed-strength that separates known-stale from live
   traces (measure both distributions; the floor is the separating value).

Not a constant to port — re-derive per corpus, like the gate bands.

## The gate

- `test/swarm/graph/gc_test.exs`: reap removes an evaporated (aged-2000-days) edge,
  keeps a fresh one; the working set drops 1→0; a much-reinforced OLD edge survives while an equally-old once-seen one is reaped (the reinforcement axis); bounded-weight — `saturation`
  monotone and `< 1` at 1e6 re-emissions.
- `bench/trace_gc.exs`: 5 churn rounds × 2000 traces (~90% evaporated) → NO-GC
  retains ~10000, WITH-GC ~1000. Run:
  `SWARM_DB_NAME=swarm_bench SWARM_DB_HOST=localhost mix run --no-start bench/trace_gc.exs`.

## Limitations (honest scope)

- **Per-kind TTL is T12 (zones); consume-on-read is T13 (leases).** This owns the
  decay-driven reap + bounded weights + ρ; the other lifecycle halves are tied,
  not duplicated.
- **Durable scheduling deferred** — the GenServer interval is in-process; an
  Oban-backed schedule is a follow-up. The reap policy is fixed.
- **Scan-cost vs working-set.** The bench shows the *working set* diverging 10×;
  raw `count(*)` is fast at 10k either way — the latency divergence shows at the
  *traversal* level (cost ∝ reachable subgraph, T1), which the bounded working set
  protects.

## Acceptance

- Reap removes evaporated, keeps reinforced; bounded weight proven; saturation
  bench shows the divergence. `mix test` 128/0; credo `--strict` clean; dialyzer 0.
