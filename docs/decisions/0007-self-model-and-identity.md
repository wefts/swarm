# ADR-7: Kernel self-model + asker identity

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Accepted (built and validated — see `../design/self-model-and-identity.md`)

## Record Completeness

Complete

## Context

Two scars:

- **P6 — no self-model.** glpi-agent told a user "I have no knowledge base" while
  2771 docs sat indexed. It could not answer "what do you know / how fresh / how
  sure" from real state.
- **P11 — no asker identity.** "my tickets" could not resolve *whose*; the fix was
  recognizing a universal identity key (the penta) across GLPI/MM/wiki/Confluence.

Swarm had `KbStatus` (a seed) and scope narrowing + `Gate.Visibility`, but no
first-class self-model and no asker-identity in the channel→Core contract.

## Decision

1. **Self-model from real state, never a guess.** `Core.status` (the `KbStatus`
   RPC) reports: graph size, **per-type inventory** (counts), **freshness**
   (last write activity), embedding-namespace stamps (ADR-6), and **live
   capabilities** (attached connectors from the registry + the consilium panel).
   On the wire, `StatusResponse` gains `inventory` (`TypeCount`), `last_activity`,
   and `capabilities`. The system answers "what do you know / how fresh / what can
   you do" by reading state, so it can never claim an empty KB while docs are
   indexed.

2. **Asker identity in the contract.** `AskRequest` gains a `viewer` — the asker's
   resolved canonical id. The kernel uses it to resolve **possessive queries**
   ("my"/"mine" — *not* bare "me", which is not an ownership signal): with a
   viewer, retrieval is narrowed to that viewer's items (the viewer matched as a
   **delimited token** in the key, not a bare substring, so a short id cannot
   match another asker — still scope-filtered); a possessive query with **no**
   viewer is **limited** (`identity_required`, a clear structured result), never a
   broad anonymous dump.

3. **Identity mapping is a channel concern.** The kernel takes an **opaque**
   `viewer` id. Mapping a platform user → that canonical id (the penta-as-
   universal-key) is a **deployment fact** that lives in the channel / `hive`
   config, never in the kernel.

## Consequences

- "What do you know / how fresh / what can you do" is answerable from state — the
  P6 scar is closed.
- "my X" resolves to the asker without prompting; an anonymous first-person ask is
  limited rather than over-broad.
- **Security boundary unchanged.** The `viewer` owner-match is a *convenience*
  narrowing for "my", **not** a security boundary — **scopes** (`Gate.Visibility`,
  ADR-5 workspace) remain the boundary. A `viewer` does not grant scope; the
  channel sets `scopes`. So "my X" is "the viewer's items *within the allowed
  scopes*". Visibility-under-load stays ADR-5's named open problem.
- The kernel stays decoupled from any platform's identity scheme (opaque id).

## Alternatives

- **Store the penta / platform identity scheme in the kernel.** Rejected —
  couples the kernel to deployment platforms; identity mapping is a `hive`/channel
  fact. The kernel takes an opaque id.
- **Infer the asker from the query.** Rejected — a guess; the not-found/identity
  must come from a resolved id the channel supplies.
- **Answer "my X" anonymously by dumping public items.** Rejected — the over-broad
  scar; an unresolved asker is limited, not guessed.
- **Owner-match as the access boundary.** Rejected — `key ILIKE %viewer%` is a
  retrieval convenience, not security; scopes are the boundary, enforced
  independently.
