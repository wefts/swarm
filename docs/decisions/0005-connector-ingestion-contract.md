# ADR-5: Connector ingestion contract — completeness owned in code

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Accepted (built and validated — see `../design/connector-ingestion.md`)

## Record Completeness

Complete

## Context

Real sources are **hostile** (the glpi-agent's hardest lesson): title-sorted +
hard list limits, **no** server-side date/range filter, a byte-ceiling that
returns EMPTY past ~N items, and partial/flaky fetches. Letting a model pick a
subset out of a raw dump **fabricated data**. The prototype survived only with a
local materialized store, delta top-up (sync only movers), and the rule
"completeness owned in code, never trust top-N."

Swarm has the right substrate — the graph as the answer surface — and a
`connector` port (`stream/1` + `describe/0`), but no *contract* that makes a
connector face this reality. T3 writes that contract; T4 proves it with a hostile
fixture. ADR-first: this precedes T4.

## Decision

1. **Two connector shapes.** `stream/1` is a *full dump* (small/ceiling-free
   sources). **`fetch/2`** is a *kernel-driven paginated pull* — the connector
   returns one `%{events, cursor, truncated?}` page and the **next cursor**, and
   the kernel drives the loop to `:done`. `fetch/2` is the hostile-source
   contract. Both are optional callbacks; a connector implements one.

2. **The kernel drives pagination to the connector's declared exhaustion.**
   `Swarm.Connector.Sync` follows the cursor to `:done` instead of trusting one
   bounded list; keyset (cursor) pagination defeats the naive offset/byte-ceiling
   that returns empty past ~N. *Honest limit:* the kernel owns the *loop*, but a
   connector that lies — returns `cursor: :done` early, or silently omits items
   within a page without `truncated?` — is the residual trust boundary (see
   point 3 and Consequences). "Owned in code" means the loop is the kernel's, not
   that a lying connector is impossible.

3. **Coverage reconciliation closes the lie where a total is known.** If the
   source can declare its size — `:expected_total` (opts) or a page's `:total`
   field — the runner compares items delivered against it and flips `complete?`
   to false on a shortfall, even when the connector said `:done`. Many real APIs
   (Confluence `size`/`totalSize`) expose this. With no declared total, an early
   `:done` is undetectable — the acknowledged residual limit, closable only by an
   independent oracle.

4. **No silent caps.** A page flagged `truncated?: true` (a real source ceiling
   that clips items) is **logged** and flips the run's `complete?` to false. A
   gap is surfaced, never silently dropped.

5. **Flaky fetches are retried** (`:max_retries`, default 2) before a run is
   declared incomplete.

6. **Demand-driven pull = backpressure.** One page at a time bounds memory, so a
   hostile source cannot flood the graph.

7. **Provenance from evidential origin, not emission instance.** A connector's
   provenance key is derived from the item's identity (e.g. its stable doc id),
   so re-emitting the same fact reuses the same key. This **mitigates** the ADR-9
   (workspace) reinforcement hole for correlated re-emission but, per
   `../../../docs/architecture/confidence-calculus.md`, does **not close** it —
   per-source caps / lineage-aware reinforcement stay the open ADR-9 decision.

8. **Idempotent upsert by stable identity** (`Store.upsert_node`, ADR-1
   workspace): re-seeing an entity resolves to the same node, never a duplicate.

9. **Delta via watermark.** With `:since` (a `DateTime`) the run is a delta: the
   connector returns only movers and the report carries the new max `watermark`
   to persist for the next run.

10. **The graph, never a raw source payload, reaches a model.** `Sync.run` returns
   a *report* (counts + completeness + watermark), never the payloads. The only
   path is connector → `Ingest` → graph; models read materialized graph state
   (gate/traverse), so a model can never be handed a connector dump to subset.

## Consequences

- Completeness is a **testable property** against a fixture (T4): a hostile set of
  N ≫ ceiling items still lands complete via pagination; a genuine ceiling shows
  up as `complete? == false` + a log, not a silent loss.
- Backpressure is structural (bounded per-page pull), satisfying the brainstorm's
  demand-driven-pull requirement without a separate mechanism.
- Provenance-lineage independence (the correlated-re-emission strength hazard)
  remains open under ADR-9; this contract narrows but does not eliminate it.
- **Residual trust boundary (acknowledged).** Without a connector-declared total,
  a connector that lies about exhaustion (early `:done`, or silent intra-page
  drops with no `truncated?`) cannot be caught — the kernel owns the loop, not an
  independent count of the source. Coverage reconciliation (point 3) closes it whenever
  a total is available; real connectors (the glpi port) MUST declare it. Edge-side
  idempotency (provenance dedup on relations) is covered by the existing
  `Store`/`Ingest` tests, not re-proven by this fixture (which emits entities only).
- Real connectors — porting Confluence + Mediawiki from `~/Code/glpi-agent` —
  become `hive/plugins` adapters implementing `fetch/2`; that is the T4 follow-up
  (`board/todo/confluence-mediawiki-connectors`), kept out of the public kernel.

## Alternatives

- **Trust a connector's top-N / single list.** Rejected — exactly what fabricated
  data in the prototype; completeness must live in the kernel loop.
- **Push-based streaming with no backpressure.** Rejected — a hostile source
  floods the graph; demand-driven pull bounds it.
- **Provenance = emission time/instance.** Rejected — it *worsens* the ADR-9 hole
  (every re-emit looks like fresh evidence); evidential-origin keys are the
  cheapest mitigation.
- **Let the connector self-report "complete".** Rejected — that is trusting top-N
  by another name; the kernel must drive the cursor itself.
