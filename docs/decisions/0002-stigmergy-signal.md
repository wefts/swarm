# ADR-2: Stigmergy signal — transactional outbox

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Accepted (built and validated — see `../design/stigmergy-signal.md`)

## Record Completeness

Complete

## Context

Swarm's coordination is stigmergic: workers do not message each other, they react
to changes in the shared graph (ADR-2 workspace, *coordination*; ADR-9 workspace,
*stigmergic-loop-stability*). The kernel already has the two adjacent halves —
graph writes (`Swarm.Graph.Store`, atomic insert/upsert) and the claim side
(`Swarm.Graph.Coordination`, fenced lease) — but **not the signal in between**:
the mechanism that turns a graph write into a worker reaction. Today nothing wakes
a worker when the graph changes; `Swarm.Ports.Worker` is a contract with no driver.

Without it, the only options are polling the whole graph (O(scan), no ordering, no
proof of completeness) or an external broker (a new service, against the
substrate-first principle). `docs/architecture/mechanisms.md` records the intended
mechanism — change-data-capture over Postgres — as a candidate to adopt. This ADR
adopts it.

A second force: the loop must be **provably lossless and correctly ordered**.
Out-of-order or silently-dropped reinforcement is exactly how a stigmergic swarm
drifts (ADR-9 workspace).

## Decision

Adopt a **transactional outbox** as the stigmergy signal:

1. **Write-in-transaction.** In the same transaction that mutates the graph
   (`Store.add_node` / `add_edge`), append a row to an `outbox` table carrying a
   **monotonic sequence**, the change kind, the target key, and a minimal payload.
   The change and its signal commit or roll back together — no lost or phantom
   signals.
2. **Single in-process tailer.** One supervised reader consumes outbox rows in
   sequence order past a persisted cursor and dispatches to the workers that care
   (via `Swarm.Ports.Worker`). Postgres `LISTEN/NOTIFY` is a low-latency **wake
   hint** only; the outbox + cursor is the source of truth (NOTIFY may coalesce or
   drop under load — never relied on for correctness).
3. **Monotonic sequence + gap detection.** If sequences arrive `1,2,4`, then `3`
   is either in flight (wait and re-read) or rolled back (skip after a bounded
   `gap_timeout`). This makes "nothing was dropped" provable, not assumed.
4. **Partition-by-key for ordered parallelism.** Changes to the same target share
   one ordered lane; different keys run in parallel — so same-target reinforcement
   stays correctly ordered (ADR-9) while throughput scales with key count.

**Outbox over direct WAL/logical-replication tail.** The outbox is
engine-agnostic, trivial to test, and needs no replication slot or `wal_level`
change. Its cost — roughly 2× WAL volume — is irrelevant at our single-node,
local-first scale. Tailing the WAL directly is cheaper but couples us to
Postgres's replication format; recorded here as the **scale-up path**, not now.

## Consequences

- **Easier:** workers react to changes without scanning the graph; the loop is
  provably lossless and ordered; one writer + one tailer keeps ordering trivial;
  validates Postgres-as-substrate from the storage spike (ADR-0 workspace).
- **Harder:** the outbox ~doubles WAL; `gap_timeout` is a real tuning knob (ADR-8
  workspace — too short skips live events, too long stalls the lane); the tailer
  is a singleton → needs supervision now and leader election for multi-node later
  (the fencing in `Coordination` is the tool).
- **Avoided:** a broker/service, and unprovable polling.

## Alternatives

- **Direct WAL / logical-replication tail.** Rejected now: engine-coupled, needs
  a replication slot + `wal_level=logical`, harder to test. Kept as the scale-up path.
- **Poll the graph for changes.** Rejected: O(scan), no ordering, cannot prove
  completeness.
- **External message broker (Kafka/Rabbit/Redis Streams).** Rejected: a new
  stateful service, against substrate-first; durability/ordering belong in Postgres.

Grounded in `../../../docs/architecture/mechanisms.md`; relates to workspace ADR-2
(coordination), ADR-8 (tuning inventory), ADR-9 (stigmergic-loop-stability), and
the kernel's `Graph.Store` / `Graph.Coordination` / `Ports.Worker`.
