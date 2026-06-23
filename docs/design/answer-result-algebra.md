---
status: built
implements: "swarm ADR-6 (Accepted) — ../decisions/0006-answer-result-algebra.md"
owner: swarm
---

# Spec: Answer-result algebra (T6)

Every `Core.ask/2` outcome is typed, so a not-found, a transport failure, and a
partial result are distinct — never a not-found masquerading as an outage, never a
raw error leaked, never a partial silently presented as complete. Implements swarm
ADR-6.

## The algebra

`answer().status :: :found | :not_found | :partial | :error`

| status | meaning | shape |
| --- | --- | --- |
| `:found` | supported answer | citations present |
| `:not_found` | lookup resolved to nothing | echoes queried terms, polite, `confidence 0.3`, no citations |
| `:partial` | some sources failed | answer flagged "Partial …", citations of what was retrieved |
| `:error` | transport/adapter failure | generic message, `confidence 0.0`, detail **logged not shown** |

## Mechanism

- **`Core.retrieve/3`** wraps the graph search: a raised DB/transport error is
  *caught* → `{:error, {:retrieval_failed, …}}` (never raised into the turn);
  empty → `{:ok, []}`. A retriever may also return `{:partial, hits, failed}`.
  The retriever is injectable (`:retriever` opt) — the default is the graph search.
- **`Core.ask/2`** maps the retrieval outcome to a typed answer at each tier
  (tier0 greeting = `:found`; tier-tools and escalate per the table above). A
  consilium synthesis failure is an `:error` (distinct from not-found), quarantined
  low-confidence, never raw panel text.
- **Wire contract**: `core.proto` `AnswerStatus` enum on `AskResponse`;
  `Swarm.Core.Server.wire_status/1` maps the kernel atom → enum.

## The gate — `test/swarm/core_result_test.exs`

| Test | Asserts |
| --- | --- |
| nonexistent lookup | `:not_found`, turn survives, polite (real retriever) |
| real hit | `:found` with citations |
| transport failure | `:error`, ≠ not_found, `confidence 0.0`, **no raw `"boom"` leak** |
| partial source | `:partial`, citations of what was retrieved, "Partial" in answer |
| not_found ≠ error | same query, injected empty vs injected error → different status + message |
| escalate found | forced-escalate + a synthesizing judge → `:found` |
| escalate error | forced-escalate + a failing judge → `:error`, no raw panel text |
| programmer bug | an injected retriever that *raises* propagates (crashes loudly) — not mislabeled `:error` |

## Limitations (honest scope)

- **Partial is injectable now, routine later.** The live path has one retrieval
  source (the graph), so it emits found/not-found/error; `:partial` is exercised
  via an injected multi-source retriever and becomes routine when connectors /
  multi-scope retrieval land. The algebra is ready; the multi-source *retrieval*
  is not built here (it is T3/T4 connectors + future fan-out).
- **Rendering is T7.** This types the result; how each status is presented
  (deterministic, per-channel) is the channel-rendering contract.

## Acceptance

- `mix test` 109/0; credo `--strict` clean; dialyzer 0; format clean.
- `core.proto` carries the status enum; the server maps it.
