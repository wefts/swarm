# ADR-6: Answer-result algebra — found / not-found / partial / error

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Accepted (built and validated — see `../design/answer-result-algebra.md`)

## Record Completeness

Complete

## Context

glpi-agent crashed a whole turn on a typo'd id — it said "GLPI may be
unreachable" when the real problem was *no such item*. A **not-found masqueraded
as an outage**. OTP "let it crash" keeps the supervised *process* alive, but the
**Core contract** never distinguished:

- "no such item" (an expected empty), from
- a transport/adapter failure (a genuine error), from
- a partial result (some sources answered, some failed).

`Core.ask` returned one shape (`answer/confidence/tier/citations`) where a
not-found was just a low-confidence string — indistinguishable, downstream, from
a failure. That is a missing result *algebra*, not an infra bug.

## Decision

`Core.ask/2` always returns a **typed** answer carrying a `status`:

- **`:found`** — a real, supported answer (with citations).
- **`:not_found`** — the lookup resolved to nothing; the queried terms are echoed;
  the turn survives, politely. Distinct from an error.
- **`:partial`** — some sources failed; the answer is present but flagged
  incomplete, never silently presented as complete.
- **`:error`** — a genuine transport/adapter failure; distinct from not-found,
  never silent, and **never a raw error string** to the user (the detail is
  logged for the operator).

Enforced by:

- **Typed retrieval** (`Core.retrieve/3`): a genuine **transport** exception
  (`Postgrex.Error`, `DBConnection.ConnectionError`) is *caught* and becomes
  `{:error, …}` — never raised into the turn. The rescue is **narrow on purpose**:
  a programmer bug (a `KeyError`, a logic fault) is **not** swallowed — it crashes
  loudly, rather than being mislabeled an "outage" (which would re-create the very
  not-found-vs-outage confusion this ADR kills). Empty is `{:ok, []}` →
  `:not_found`.
- **The contract on the wire**: `core.proto` gains an `AnswerStatus` enum
  (`FOUND/NOT_FOUND/PARTIAL/ERROR`) on `AskResponse`; `Swarm.Core.Server` maps the
  kernel atom to it, so a channel can render per-status.

## Consequences

- A channel can give a not-found its own UX (T7) distinct from an outage banner;
  the turn never dies on an expected empty.
- The raw-error-to-user leak is closed: a retrieval failure yields a polite,
  generic message with the detail logged, not an adapter stack string.
- **Partial is modeled and producible now via an injectable retriever; the live
  single-source (graph) path emits found/not-found/error today.** Partial becomes
  routine once multi-source retrieval (connectors, multiple scopes) lands — the
  algebra is ready for it rather than retrofitted.
- `status` is additive to the existing answer shape; existing callers that ignore
  it still work.

## Alternatives

- **Collapse not-found into a low-confidence answer.** Rejected — the exact scar;
  downstream cannot tell absence from a weak answer or an outage.
- **Raise on an empty/expected result.** Rejected — that is what crashed the turn;
  let-it-crash is for the process, not an expected empty.
- **One generic error string for everything.** Rejected — conflates outage with
  absence with partial; the channel then cannot respond correctly.
