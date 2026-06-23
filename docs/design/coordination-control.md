---
status: built
implements: "swarm ADR-12 (Accepted) — ../decisions/0012-coordination-control.md"
owner: swarm
---

# Spec: Coordination control (T13)

Who reacts to which trace, and when — without graph-wide scans or silent stalls.
Implements swarm ADR-12.

## Pattern-match subscriptions (routing)

`Swarm.Stigmergy.Dispatch` (ADR-2): workers `subscribe(kinds, handler)` to the
change kinds they handle; the tailer routes each consumed outbox row to the
per-`target_key` ordered lane, invoking only interested handlers. No worker scans
the graph. Subscription is by change kind today; richer typed target predicates
(e.g. `type:connector_status, state:drifted`) are a follow-up.

## Stagnation monitor — `Swarm.Coordination.Stagnation`

- **Bystander guard (deduped)**: `Dispatch` calls `record_unmatched/1` when a row
  matches no subscription → recorded ONCE per change kind (`ON CONFLICT (reason,
  ref) DO NOTHING`), so a high-frequency unhandled kind surfaces once, not per write.
- **Stalled-claim watchdog**: a config-gated `Stagnation` GenServer periodically
  runs `scan_stalls/1`, which records (deduped) each claimable `coordination` node
  with no `claimed_by` older than the TTL. Surfacing is operational, not on-demand.
- Inspectable: `recent/1`, `count/0`. A below-gate-threshold *query* escalates to
  the consilium (not a stall); the abandoned graph trace is what this catches.

## The gate — `test/swarm/coordination/stagnation_test.exs`

| Test | Asserts |
| --- | --- |
| bystander deduped | the SAME unhandled kind dispatched 5× → `stagnant` count 1 (one row) |
| matched not surfaced | a subscribed row runs its handler, `stagnant` count 0 |
| stalled claim | `scan_stalls(60)` surfaces an old unclaimed `coordination` node, deduped on re-scan; a fresh one is not |

## Limitations (honest scope)

- **Subscription is by change kind**, not yet a rich node/edge target predicate —
  the bystander/stall hazards are addressed; finer routing is a follow-up.
- **The watchdog records but does not escalate** — it surfaces stalls to the
  `stagnant` table + logs; routing them to a human/fallback escalation sink is a
  follow-up. The detection + periodic scan are built.
- **No explicit task state machine** (the card's optional MetaGPT SOP item) — a
  later refinement.

## Acceptance

- Bystander trace surfaced (not silently dropped); a matched row not surfaced; a
  stalled claim surfaced by the scan. `mix test` 139/0; credo `--strict` clean;
  dialyzer 0.
