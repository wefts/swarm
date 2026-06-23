# ADR-9: Demand-driven backpressure + poison/DLQ

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Accepted (built and validated — see `../design/backpressure-and-dlq.md`)

## Record Completeness

Complete

## Context

The graph is an unbounded shared buffer: if connectors **push**, a hostile or
high-volume source overwhelms ingest and the graph (the practical half of N1), and
one malformed trace must not deadlock a stage. The pieces were partly present —
`Ingest.Queue` already bounds and rejects-on-overflow, `Connector.Sync` (ADR-5)
pulls one page at a time, and the stigmergy outbox (ADR-2) writes the trace and
enqueues its reaction in **one** transaction. The missing piece was a **poison
path**: an un-processable trace was either silently lost or — after the ADR-4
write contract — *raised* into the pipeline.

## Decision

1. **Demand-driven pull is the backpressure on the connector→graph flow** (the
   real, on-path mechanism): `Connector.Sync` drives `fetch/2` **one page at a
   time** (ADR-5) and ingests each page before pulling the next, so memory is
   bounded by `page_size`, **not** by source size — a 1M-item source is processed
   in bounded pages, never buffered whole. A hostile source hits this pull, not an
   unbounded buffer. *Honest scope:* `Ingest.Queue` (a bounded reject-on-overflow
   buffer) is a **stub for a future push/async ingest path and is NOT wired into
   the connector flow** — the connector path calls `Ingest.ingest/1` directly. The
   backpressure that is actually delivered today is the pull; the queue's policy
   is fixed for when a push path needs it, but it is not on the live path.

2. **Transactional write-trace + enqueue-reaction** is the stigmergy outbox
   (ADR-2): the graph mutation and its reaction signal commit or roll back
   together, so "react through the graph, retry freely" is safe with the ADR-1/4
   idempotency keys.

3. **Poison/DLQ.** An ingest event the pipeline cannot process — malformed shape,
   bad timestamp, missing provenance, or a **graph-contract violation (ADR-4)** —
   is **quarantined to a `dead_letter` zone with its reason** (`Ingest.DeadLetter`),
   never silently dropped and **never raised** into the pipeline. The whole
   event's write is one transaction, so a bad relation rolls back rather than
   half-writing; ingest returns `{:error, {:quarantined, reason}}` and **keeps
   running** for the next event.

## Consequences

- A flood is bounded (pull + bounded queue), not an OOM; a poison trace is
  durable, inspectable (`DeadLetter.count/recent`), and terminal (it does not
  re-enter ingest on its own).
- The ADR-4 write contract no longer turns a malformed entity into a kernel crash:
  `upsert_node`'s fail-loud `ArgumentError` and `add_edge`'s `{:error, …}` are both
  caught at the ingest boundary and quarantined.
- **Durable queue deferred.** `Ingest.Queue` is the in-memory bounded stub; the
  durable Oban-on-Postgres queue (system architecture §7) is a follow-up — the
  *policy* (reject-on-overflow, quarantine-not-drop) is fixed here, the durable
  *substrate* is not.

## Alternatives

- **Push-based ingestion (no backpressure).** Rejected — a hostile source floods
  the graph; demand-driven pull bounds it by construction.
- **Silently drop a poison trace.** Rejected — the failure becomes invisible; the
  DLQ records it with a reason.
- **Let a poison trace raise / block the stage.** Rejected — one malformed event
  would stall the pipeline; it is caught and quarantined, the stage continues.
- **Grow the buffer to absorb bursts.** Rejected — unbounded mailbox = deferred
  OOM; reject-on-overflow with a logged signal is the bounded policy.
