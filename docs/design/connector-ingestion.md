---
status: built
implements: "swarm ADR-5 (Accepted) — ../decisions/0005-connector-ingestion-contract.md"
owner: swarm
---

# Spec: Connector ingestion (T3 contract + T4 proof)

How a connector turns a hostile external source into complete, idempotent graph
state — without ever handing a model a raw dump. Implements swarm ADR-5. Sits
between the `connector` port (`../../../docs/architecture/ports.md`) and
`Swarm.Ingest`.

## The port — `Swarm.Ports.Connector`

Two optional shapes; a connector implements one:

| Callback | Shape | For |
| --- | --- | --- |
| `stream(opts) :: Enumerable.t()` | full dump, yielded lazily | small / ceiling-free sources (files) |
| `fetch(cursor, opts) :: {:ok, page} \| {:error, term}` | kernel-driven paginated pull | hostile sources (limits, ceilings, flaky) |

`page = %{events: [event], cursor: cursor | :done, truncated?: boolean}`.
`describe/0` reports `:name`, `:kind`, `:sync_modes` (`[:full, :delta]`).

## The runner — `Swarm.Connector.Sync`

`Sync.run(module, opts) :: {:ok, report} | {:error, reason}`. It owns
completeness:

- drives `fetch/2` from `:start`, following `cursor` to `:done` (or consumes
  `stream/1` as one exhaustive page);
- feeds every event through `Swarm.Ingest`; counts ingested / duplicates / errors;
- **retries** a failed `fetch/2` up to `:max_retries` (default 2) before marking
  the run incomplete;
- on `truncated?: true`, **logs** a ceiling warning and sets `complete? = false`;
- tracks the max `occurred_at` as the `watermark` to persist;
- with `:since` (a `DateTime`), runs in `:delta` mode (connector returns only
  movers);
- **coverage reconciliation**: if a total is known (`:expected_total` opt or a
  page's `:total`), a delivered-vs-total shortfall flips `complete? = false` even
  when the connector said `:done` — the guard against a connector lying about
  exhaustion. With no declared total this is undetectable (documented limit).

`report = %{mode, ingested, duplicates, errors, pages, ceilings, complete?, watermark}`
— counts and the watermark, **never the payloads**.

## Invariants (swarm ADR-5)

- **Completeness in code, not top-N** — the kernel follows the cursor; a connector
  cannot truncate the set by returning a bounded list.
- **No silent caps** — a real ceiling is logged + `complete? == false`.
- **Demand-driven pull** — one page at a time; a hostile source cannot flood.
- **Evidential-origin provenance** — mitigates (does not close) the ADR-9
  reinforcement hole; lineage caps stay open there.
- **Graph, not payload, reaches a model** — `Sync` returns a report; the only path
  is connector → `Ingest` → graph.

## The proof — `Swarm.Test.HostileConnector` (T4)

A reference connector against a hostile fixture: title-sort + per-page limit +
keyset pagination + flaky page + byte ceiling. The contract test
(`test/swarm/connector/sync_test.exs`) is the ground-truth gate:

| Test | Asserts |
| --- | --- |
| completeness | 250 items, page 50 → all 250 in the graph (== ground truth), `complete?`, 5 pages |
| flaky retry | `flaky_page` fails once → run still completes 250 |
| byte ceiling | `ceiling_page` clips half → `complete? == false`, `ceilings == 1`, loss logged, `ingested < 250` |
| delta | after full, `since: watermark` → only the 3 movers ingested |
| no raw payload | report has counts/watermark keys, no `:events` |
| bad connector | implements neither callback → `{:error, …}` |
| lying `:done` | early `:done` + `expected_total` → `complete? == false`, shortfall logged |
| limit (honest) | lying `:done` with NO declared total → reads `complete?` (undetectable) |

## Follow-up

Real connectors — porting **Confluence + Mediawiki** from `~/Code/glpi-agent`
(`src/agent/kb/{confluence,wiki}.py`) as `hive/plugins` adapters implementing
`fetch/2` — are tracked in `board/todo/confluence-mediawiki-connectors`. They
reuse the prototype's fetch + markup-strip + link-graph extraction and add
evidential-origin provenance, `occurred_at` (UTC), scope, NFC — all now governed
by this contract.

## Acceptance

- Contract test green (completeness / idempotency / ceiling-logged / delta-movers
  / no-raw-payload / lying-`:done`-reconciliation). `mix test` 95/0; credo
  `--strict` clean; dialyzer 0. Independent critic SOUND-WITH-CAVEATS; its central
  fix (the early-`:done` trust hole) applied as coverage reconciliation + an
  honest documented limit.
- ADR merged before the real connectors (T4 follow-up) start.
