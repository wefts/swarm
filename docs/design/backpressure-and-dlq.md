---
status: built
implements: "swarm ADR-9 (Accepted) — ../decisions/0009-backpressure-and-dlq.md"
owner: swarm
---

# Spec: Backpressure + poison/DLQ (T10)

How a hostile/high-volume source is bounded and how a poison trace is quarantined
instead of dropped or raised. Implements swarm ADR-9.

## Backpressure

- **Demand-driven pull (the real, on-path mechanism)** — `Swarm.Connector.Sync`
  drives `fetch/2` one page at a time (ADR-5), ingesting each page before pulling
  the next. Memory is bounded by `page_size`, not source size — a hostile/huge
  source is processed in bounded pages, never buffered whole. Tested:
  `sync_test.exs` "bounded pull" (a 600-item source → 12 bounded pages).
- **Transactional enqueue** — the stigmergy outbox (ADR-2) writes the trace + its
  reaction signal in one tx.
- **`Ingest.Queue` is NOT on this path** — it is a bounded reject-on-overflow
  buffer kept as a stub for a future push/async ingest path; the connector flow
  calls `Ingest.ingest/1` directly. The policy (reject-on-overflow) is fixed for
  when a push path needs it, but it delivers no backpressure on the live flow.

## Poison/DLQ (T10)

- `Swarm.Ingest.DeadLetter` — a `dead_letter` table; `quarantine(event, reason)`
  records the payload + reason, `count/0` + `recent/1` inspect it. The sink never
  fails (an unencodable payload is itself recorded).
- `Swarm.Ingest.ingest/1` quarantines on:
  - **normalize failure** (bad timestamp, missing provenance, bad shape), and
  - **write failure** — a graph-contract violation (ADR-4): `upsert_node`'s
    fail-loud `ArgumentError` and `add_edge`'s `{:error, …}` are caught at the
    ingest boundary. The event's write is one transaction → a bad relation rolls
    back, never half-writes.
- Returns `{:error, {:quarantined, reason}}`; the pipeline keeps running.

## The gate — `test/swarm/ingest/dead_letter_test.exs`

| Test | Asserts |
| --- | --- |
| bad timestamp | quarantined with a `bad_timestamp` reason; `count == 1` |
| contract violation (bad type) | quarantined `{:contract, _}` — **not raised** |
| pipeline survives | a good event right after a poison one still writes |
| missing provenance | quarantined `{:missing, :provenance}` (not a silent drop) |

## Limitations (honest scope)

- **Durable queue deferred.** `Ingest.Queue` is in-memory (bounded); the durable
  Oban-on-Postgres queue is a follow-up. The *policy* (reject-on-overflow,
  quarantine-not-drop) is fixed; the durable *substrate* is not.
- **No automated DLQ replay.** Quarantined traces are inspectable but not
  auto-reprocessed (a terminal sink by design); replay is an operator action / a
  follow-up.

## Acceptance

- Poison → DLQ with reason, pipeline survives; a poison relation rolls back the
  whole event (asserted). A flood is bounded by the demand-driven pull (asserted:
  600 items → 12 bounded pages). `mix test` 124/0; credo `--strict` clean;
  dialyzer 0.
