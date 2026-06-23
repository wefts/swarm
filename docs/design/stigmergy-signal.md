---
status: built
implements: "swarm ADR-2 (Accepted) — ../decisions/0002-stigmergy-signal.md"
owner: swarm
---

# Spec: Stigmergy signal (transactional outbox)

How a graph write becomes a worker reaction. Implements swarm ADR-2. Sits between
`Swarm.Graph.Store` (writes) and `Swarm.Ports.Worker` (handlers); complements
`Swarm.Graph.Coordination` (the claim/lease side) and is distinct from
`Swarm.Ingest.Queue` (external → graph).

## Data shape — the `outbox` table

Written in the **same transaction** as the graph mutation.

| Column | Type | Note |
| --- | --- | --- |
| `seq` | `bigserial` PK | monotonic sequence; the ordering + gap key |
| `change` | `text` | kind, e.g. `node_added`, `edge_reinforced` |
| `target_key` | `text` | partition key (e.g. `"node:<id>"`, edge natural key) |
| `payload` | `jsonb` | minimal: ids + what a worker needs to decide relevance |
| `idem_key` | `text` | stable key derived from the change (crash-safe re-processing) |
| `inserted_at` | `timestamptz` | |

A separate `outbox_cursor` row persists the tailer's committed position.

> Built: the custom Postgrex types module (pgvector) doesn't decode `jsonb` on raw
> queries, so the tailer decodes `payload` in-app with `Jason.decode!/1`.

## Components

1. **Write-in-tx** — `Graph.Store.add_node`/`add_edge` append an outbox row inside
   their transaction (edges only when reinforced — no-op re-sees stay silent); the
   write and its signal are atomic (commit/rollback together). *Built:* `upsert_node`
   (the ingest re-see path) does not yet emit — tracked in `board/todo/upsert-node-emit`.
2. **Tailer** (`Swarm.Stigmergy.Tailer`, supervised GenServer, singleton) —
   - woken by Postgres `LISTEN/NOTIFY` (hint only) **or** a poll fallback;
   - reads `outbox` rows with `seq > cursor` in `seq` order;
   - **gap detection:** if the next `seq` is non-contiguous, wait up to
     `gap_timeout`, re-read; if still missing, skip (rolled back) and log;
   - dispatches each row to interested workers, then advances + persists the
     cursor **transactionally with** marking the row handled.
3. **Subscription / dispatch** (`Swarm.Stigmergy.Dispatch`) — workers register the
   `change` kinds they care about (a fun or a `Ports.Worker` module); the tailer's
   handler routes each row to them, crash-safe.
4. **Partition-by-key** (`Swarm.Stigmergy.Lane`) — dispatch routes each row to the
   ordered lane for its `target_key` (one process per key) and lanes run in
   parallel, so same-target reinforcement is ordered (ADR-9 workspace) without
   serializing unrelated work. A lane runs async, so a slow handler never stalls
   the tailer. Key choice = consistency grain (per-node / per-edge), a tuning decision.

## Behaviour & invariants

- **Lossless + ordered:** every committed graph change has exactly one outbox row;
  the tailer consumes strictly in `seq` order; gaps are resolved (wait) or proven
  rolled-back (skip after timeout) — never silently dropped.
- **Idempotent re-processing:** after a crash the tailer resumes from the cursor;
  workers dedup on `idem_key`, so replays converge (mechanisms.md, idempotency).
- **NOTIFY is a doorbell, not the truth:** correctness comes from outbox + cursor;
  NOTIFY only lowers latency and may be dropped.
- **Fail-loud:** typed results the caller branches on (house style).

## Tuning (ADR-8 workspace)

`gap_timeout` (skip-after), poll-fallback interval, max dispatch concurrency
(lanes). Defaults are placeholders until measured.

## Out of scope

Multi-node tailer (leader election via `Coordination` fencing) and direct WAL-tail
(the scale-up path, ADR-2) — later.

## Build order (thin slice first)

1. `outbox` table migration + write-in-tx from `Graph.Store`.
2. Tailer reads rows in `seq` order past a cursor (no gap logic yet) → observe a
   write end to end.
3. Gap detection (wait/skip with `gap_timeout`).
4. Worker subscription + dispatch via `Ports.Worker`.
5. Partition-by-key lanes (ordered same-key, parallel cross-key).
