---
date: 2026-06-23
status: Draft
implements: "swarm ADR-1 (Proposed) — ../decisions/0001-model-residency-scheduler.md"
owner: swarm
---

# Spec: Model Residency Scheduler

## Problem

One GPU, finite unified memory (~117 GiB on GB10), many model consumers (cheap
continuous workers + rare expensive consilium escalations). The default runtime
policy thrashes and degrades silently (see ADR-1 / the residency spike). We need
a kernel scheduler that gives the illusion of "all models available" with bounded
latency, without globally shrinking context.

## Goals / non-goals

- **Goals:** predictable latency under contention; cost- and role-aware
  residency; never evict a model mid-inference; early-exit for the consilium
  panel; policy tuned from telemetry.
- **Non-goals:** replacing the model runtime (we still call Ollama via the ML
  service); multi-node GPU scheduling (single node first; the Port keeps the door
  open); training.

## Architecture

A single supervised broker owns GPU residency; everything else asks it.

```text
caller ──run / with_model──▶ Swarm.ML.Residency (Port API)
                                 │  (typed, sync call)
                                 ▼
                        Residency.Broker (GenServer, 1 per GPU)
                          - priority admission queue
                          - resident set + policy engine
                          - in-flight guard (no evict mid-run)
                                 │ load / evict / run
                                 ▼
                        Swarm.ML.Boundary (gRPC → ML service → Ollama)
```

### Components (each small, single-purpose, independently testable)

1. **`Swarm.ML.Residency` (Port / public API).**
   - `run(model_ref, request, opts)` — force the model (load if cold), run the
     RPC, return the typed result. Caller is oblivious to residency.
   - `with_model(model_ref, fun, opts)` — lower-level: hold a lease on a resident
     model for the duration of `fun`.
   - `opts`: `:priority` (`:realtime | :normal | :background`), `:num_ctx`,
     `:keep_warm`. Defined as a behaviour so a test double or an external
     scheduler plugin can replace it.

2. **`Residency.Broker` (GenServer, one per GPU id).**
   - Owns the **resident set** (model → {size, ctx, last_used, hits, leases}).
   - **Admission:** a priority queue. A `:realtime` request may preempt
     `:background` residents to make room; `:background` waits if the fleet is
     saturated.
   - **In-flight guard:** a model with active leases is never evicted; eviction
     drains first (lease count → 0), then unloads.
   - Emits telemetry on every load/evict/run (for tuning + the soak/bench).

3. **`Residency.Policy` (pure module).**
   - `plan(resident_set, request, budget) :: {:admit, evictions} | {:queue} | {:reject}`.
   - Cost-aware working-set: score = f(recency, frequency, load_cost_GiB,
     role_weight). Pure and deterministic → unit-testable with no GPU.
   - Reads thresholds from the tuning inventory (ADR-8 workspace), not hardcoded.

4. **`Residency.Budget`.**
   - Tracks usable VRAM and per-model footprint = weights + KV(ctx). Footprint is
     **measured** (from runtime `ps` / load telemetry), not guessed — the spike
     showed weights alone mislead (context dominates).

5. **Lazy panel integration (`Swarm.Consilium`).**
   - The panel is a **lazy stream** of `Residency.run/3` thunks. The aggregator
     forces members until a quorum / early-exit condition holds (ADR-7
     workspace), so unneeded members are never loaded. The judge runs at
     `:realtime` priority.

### Preemption safety (the one hard invariant)

A loaded model is a shared mutable resource. Rules:

- Leases are reference-counted; eviction requires `leases == 0`.
- Preemption marks a victim **draining** (no new leases), waits for in-flight to
  finish (bounded by a deadline), then unloads. If the deadline passes, the
  high-priority request queues rather than corrupting state.
- All residency mutations are serialized through the Broker (single writer).

## Telemetry & tuning (ADR-8 workspace)

Record per event: load time, evict count, footprint (weights/KV), hit/miss,
queue wait, partial-offload occurrences. These calibrate the policy weights and
the keep-warm set. The dockerization soak harness (`hive/scripts/soak.sh`) is
extended to exercise the consilium path, not just embeddings.

## Testing

- **Policy:** pure unit tests — given a resident set + request + budget, assert
  the eviction plan. No GPU needed.
- **Broker:** property tests for the lease/preemption invariant ("a model with
  leases > 0 is never unloaded") using a mock loader.
- **Integration:** real GB10 — load the fleet, drive concurrent `:realtime` +
  `:background` requests, assert no mid-inference eviction and bounded
  high-priority latency; compare thrash vs the naive baseline.

## Build order (thin slice first)

1. Port API + Broker with a trivial policy (admit-if-fits, LRU evict) + lease
   guard. Prove the illusion + the invariant.
2. Cost/role-aware `Residency.Policy` + Budget from real telemetry.
3. Lazy panel + priority preemption in the consilium.
4. Stigmergic demand signals on the blackboard (optional, ADR-2 workspace).

## Open questions

- Where does footprint truth come from — runtime `ps` polling vs a load-time
  probe? (Spike: `ollama ps` reports live size incl. KV — usable.)
- Preemption drain deadline default (tuning inventory).
- Per-model `num_ctx` policy: fixed vs per-request vs adaptive under pressure.
