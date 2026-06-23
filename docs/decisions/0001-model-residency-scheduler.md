# ADR-1: Model Residency Scheduler

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../docs/decisions/`.

## Status

Proposed

## Record Completeness

Complete

## Context

The local model fleet shares one scarce resource: GPU memory. On the reference
node (NVIDIA GB10, ~117 GiB unified) a spike measured the consilium fleet's real
footprint:

- At a modest context (`num_ctx=4096`) four fat models stay resident —
  `llama3.3:70b` (45 GiB) + `qwen3.6:35b` (22) + `glm-4.7-flash` (19) +
  `qwen3:14b` (10) ≈ **96 GiB**; the fifth does not fit and the runtime
  **partial-offloads** (some layers to CPU = silent degradation).
- **Context length dominates footprint, not weights.** At the models' default
  context (256k tokens) the KV cache explodes and only ~2 fat models fit.
- The default runtime policy (LRU + a fixed max-loaded cap) thrashes under
  contention: evicting the 70b judge means a ~45 GiB reload — an extremely
  expensive "context switch" — and it has no notion of model role, load cost, or
  request priority.

The kernel's workload is cost-asymmetric by design (ADR-4 workspace): many cheap
workers run continuously, while large models are rare, deliberate escalations
(ADR-7 workspace; Domain 4 consilium). All of them contend for the same VRAM. We
need the *illusion* that every model is available, over limited memory, with
**bounded, predictable** behaviour — without globally crippling context to make
everything fit.

## Decision

Introduce a **Model Residency Scheduler**: a single kernel-owned broker that
mediates *all* model use behind a typed Port, treating VRAM as a schedulable
resource and loaded models as preemptible residents. It composes three borrowed
mechanisms:

1. **Residency as time-slicing (the OS scheduler).** VRAM is the "CPU", a model
   is a "process", and load/evict is a **context switch** — costly, so minimize
   it. Replace naive LRU with a **cost-aware working-set** policy weighing
   recency, frequency, **load cost** (GiB to reload), and **role** (a judge is
   dearer than a background classifier). High-cost / high-role models may be
   pinned or kept warm.

2. **Priority message-passing broker (QNX / OTP).** A supervised `GenServer`
   owns the GPU. Requests are *messages* with priorities; a realtime request
   (consilium judge) can **preempt** a low-priority one (background worker).
   Admission control keeps behaviour deterministic under pressure. The BEAM's
   own preemptive, reduction-counted scheduler is the muse — we build the same
   for models.

3. **Laziness (Haskell).** A model reference is a **thunk**, forced (loaded) only
   on demand (call-by-need), then **memoized** (kept resident until reclaimed
   under pressure). The consilium panel is a **lazy stream**: force only as many
   members as the judge actually needs — if a quorum already agrees, the
   remaining members are never loaded. This turns the cost-asymmetry *principle*
   into a runtime *saving*.

The scheduler is exposed as a typed Port with a `with_model(ref, fun)` shape
(mirroring `Swarm.ML.Boundary.with_channel/2`): the caller is oblivious to
whether the model was already resident or just loaded. Policy parameters
(working-set size, keep-warm set, preemption thresholds) live in the **tuning
inventory (ADR-8 workspace)** — measured, not intuited. Demand can be surfaced
**stigmergically** on the blackboard (ADR-2 workspace) so residency follows
demand density rather than a central oracle.

## Consequences

- **Easier:** predictable latency under contention; the whole fleet is usable
  without globally cutting context; a rare long-context call gets memory by
  temporarily evicting panel members; the cost-asymmetry principle is realized at
  runtime (unneeded models are never forced).
- **Harder:** a new scarce-resource scheduler must be designed, tuned, and
  tested; the eviction policy must be calibrated from telemetry; correctness
  under preemption requires care (never evict a model mid-inference; drain
  first).
- **Avoided:** silent thrash and partial-offload degradation as the default
  behaviour.

## Alternatives

- **Rely on the model runtime's built-in policy (LRU + max-loaded cap).**
  Rejected: no awareness of role, load cost, or request priority; thrashes; no
  early-exit.
- **Globally small context for all models.** Rejected: discards long-context
  capability for everyone just to make memory fit.
- **Static pinning / one-model-at-a-time.** Rejected: wastes unified-memory
  headroom and serializes the inherently parallel consilium panel.

Grounded in the GB10 residency spike; relates to workspace ADR-2 (coordination),
ADR-4 (cost asymmetry), ADR-7 (LLM I/O), and ADR-8 (tuning inventory).
