# ADR-15: Dashboard projection RPCs — deliberation / neighborhood / activity

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Proposed (design phase — wire contracts in `../design/dashboard-projection-rpcs.md`;
the kernel build is a separate, gated phase)

## Record Completeness

Complete

## Context

The operator asked for a dashboard to **see how the swarm thinks** — what it
deliberated, the connections in the graph, the jobs it ran. The channel is a gRPC
client of the Core API and **never reads the graph DB** (hive ADR-1); a dashboard
is exactly the surface tempted to `SELECT`. So every datum needs a new typed,
**scope-enforcing, viewer-aware** Core RPC. These contracts are load-bearing and
partly irreversible (a wire shape; a retention decision), so they earn a design
pass before any code.

An architect read of the kernel (recorded on the epic card) establishes the cut
this ADR rests on — **do not re-litigate it**:

- **`Consilium.deliberate/2`** already returns
  `%{answer, confidence, disagreement, panel: [%{model, answer}], judge}` on every
  **escalated** `Ask`. Today that verdict is **discarded** after `AskResponse` is
  built — it is never persisted.
- **`Graph.Traverse.walk/3`** runs a scope-enforced, node-bounded relaxation over
  the populated `swarm_prod` graph (ADR-3), filtering on both `node.scope` and
  `edge.visibility_scope`. It returns reached node **ids** (+ confidence + depth) —
  not the edges, types, or keys a connection view needs.
- The **`outbox`** (`seq, change, target_key, payload, inserted_at`) gives a thin
  dispatch slice now; rich worker outcomes (`entity_resolution_audit`,
  `enrichment_decision/pass`) populate when the cognitive loop runs.

So **`Deliberation` + `Neighborhood` are buildable against today's kernel**; only
the rich `ActivityFeed` content is loop-gated. The dashboard is the observability
instrument for the very loop the operator hot run turns on — complementary to it,
not blocked by it.

## Decision

The Core API gains three **read-only, scope-enforcing, viewer-aware projection
RPCs**. Each takes `scopes` + `viewer` (the existing `AskRequest` convention,
ADR-7) and the **kernel enforces**; the channel only passes an authenticated
identity. Each returns ids / typed fields the channel renders **verbatim**
(presentation determinism, T7) — never prose, never a raw row, never a payload
blob. Each carries the ADR-6 `AnswerStatus` so absence (`NOT_FOUND`) is distinct
from an outage (`ERROR`). **On any non-`FOUND` status the response carries only
`status` — every other field is zero-valued** (a review-step finding: a `NOT_FOUND`
must never carry a `created_at`, partial payload, or any value read from a
found-but-unauthorized row, which would leak existence + timing). Full message
shapes: `../design/dashboard-projection-rpcs.md`.

1. **`Deliberation(ask_ref)` — a separate RPC, backed by bounded kernel retention.**
   The kernel **persists** each escalation verdict keyed by a minted, **opaque,
   high-entropy** `ask_ref`, stamped with the asking `viewer` + the `effective_scope`
   the retrieval ran under. `Deliberation(ask_ref)` returns the panel-vs-judge view
   **only** when the requesting `viewer` is the owning asker **and** the request's
   current `scopes` still cover that `effective_scope` — so a viewer who later loses
   a scope cannot re-open a deliberation derived under it (owner-match alone would be
   a stale-authorization bypass; a council finding). `AskResponse` gains an `ask_ref`
   (set only when an escalation produced a deliberation; empty otherwise — the
   channel shows the "see the thinking" affordance only when it is present). This
   settles the one real fork — see below.

2. **`Neighborhood(node_id, depth, …)` — a bounded, scoped projection over
   `Traverse`.** It reuses `Traverse`'s scope-enforced edge query as the mechanism,
   then hydrates the visible node set (`id, type, key, scope`) and projects the
   typed **edges** among them (`src_id, dst_id, relation, …`). It is **bounded by
   contract**: `depth ≤ 2` (clamped), a node ceiling (`≤ 50`, clamped), and a
   `relation_types` filter — **never the full hairball**. The center node must be
   visible to the viewer's scopes or the result is `NOT_FOUND`; an edge appears only
   when its **own** `visibility_scope` is within the request scopes *and* both
   endpoints are in the returned in-scope set (an edge can be private between two
   visible nodes — endpoint-visibility alone is insufficient; a council finding).

3. **`ActivityFeed(cursor, …)` — a poll RPC, not a stream.** The channel polls
   with an **opaque cursor** (matches the dashboard's refresh cadence; no long-lived
   gRPC streams, no backpressure). It projects **scope-safe typed events** —
   `kind, at, subject_type, outcome, count` — derived from the `outbox` (thin now)
   and the ER/enrichment audit tables (rich when the loop runs). The raw
   `payload`/`target_key`/node `key`/**raw sequence number** is **never** put on the
   wire: the kernel resolves each event's referenced node scope and **drops events
   whose subject is out of the viewer's scopes** (default-deny — no redacted
   placeholder, which would leak private-activity volume), advancing the opaque
   cursor **server-side past the filtered events** so hidden-event volume/timing is
   not inferable from sequence gaps (the council's headline fix); `count` aggregates
   in-scope subjects only. The honest per-answer trace already ships in each post;
   this is the complementary kernel job feed.

### The fork, settled: separate `Deliberation` RPC + retention (not a field on `AskResponse`)

**Chosen:** a separate `Deliberation(ask_ref)` RPC with the kernel retaining each
verdict. **Rejected:** an optional `deliberation` field on `AskResponse`.

Why retention wins, despite its cost (new kernel state + a retention/GC policy):

- **Re-openability is the named requirement.** "Re-open a past conversation" is a
  shipped, viewer-scoped feature, and the operator ask is explicitly
  *cross-conversation* ("see how the swarm thinks"). A field on `AskResponse` is
  **ask-time only** — it reaches the one caller of the one `Ask` and is gone. Keyed
  retention lets any authorized surface re-open the panel later, and lets a future
  dashboard browse deliberations across conversations.
- **The kernel stays the projection + scope authority.** Re-serving from a stored,
  kernel-owned, viewer-stamped row keeps the kernel the single place that decides
  what a viewer may see (ADR-1; "scope is the kernel's, always"). The alternative
  pushes kernel-internal cognition state into the channel's own log and makes the
  channel re-serve it — an ADR-1-adjacent smell.
- **The hot answer path stays lean.** N full panel texts on every escalated
  `AskResponse` bloats the answer contract with data ~all callers ignore and
  couples answering to a debugging/observability concern. "Show me the thinking" is
  a separate, deliberate action — a separate RPC matches it.

**Cost accepted, and bounded:** a `deliberation` store keyed by `ask_ref`, stamped
with `viewer` + `scopes` + `created_at`, GC'd by the existing decay-driven trace
lifecycle (ADR-10) under a **configurable** TTL + max-row cap (the build wires them
as config keys, not constants, so they tune without a code change; recommended
defaults `enabled: true`, `retention_ttl_days: 30`, `max_rows: 10_000` —
rationale + the kill-switch in the spec). **Anonymous escalations are not retained**
(no `viewer` ⇒ no `ask_ref` ⇒ nothing to re-open and nothing ownerless on disk).
The persist is a single insert **after** `deliberate/2` returns (post-LLM) — it
does not hold a connection across the model call.

## Consequences

- The "thinking" surface (deliberation), the "connections" surface (neighborhood),
  and the "activity" surface (job feed) are each reachable through one typed,
  scope-enforced RPC — the channel never reads the DB, and a private datum cannot
  cross the wire to a viewer without the scope.
- **`Deliberation` + `Neighborhood` are buildable now** (loop-independent);
  `ActivityFeed`'s thin slice ships now and its rich content lands when the loop
  runs — the contract is ready rather than retrofitted.
- **New kernel state + a retention/GC policy** are introduced for deliberation —
  the partly-irreversible part of this decision. Mitigated by reuse of ADR-10 GC,
  a viewer-ownership gate, a TTL + cap, and no anonymous retention.
- `Neighborhood` is bounded by contract, so a dense hub cannot return a hairball or
  blow the traversal budget (ADR-3 `truncated` is surfaced).
- `ActivityFeed` as **poll, not stream**, keeps the channel a simple polling client
  and avoids long-lived streams through the web tier; the cost is refresh latency,
  which a dashboard tolerates.
- The contracts are additive (new RPCs + one additive `AskResponse` field); existing
  `Ask`/`KbSearch`/`KbStatus` callers are unaffected.

## Alternatives

- **`deliberation` as a field on `AskResponse` (no new state).** Rejected — see the
  fork above: ask-time only, not re-openable, bloats the hot path, and shifts the
  projection authority to the channel.
- **`Neighborhood` as a thin wrapper that returns the full reachable set.** Rejected
  — an unbounded neighborhood is the hairball the operator explicitly does not want
  and a traversal-cost hazard; bounding (depth/node-ceiling/relation filter) is part
  of the contract, not a render-time afterthought.
- **`ActivityFeed` as a server-streaming RPC.** Rejected — a long-lived stream
  through the web channel adds backpressure and connection-lifecycle complexity a
  periodic dashboard does not need; a `seq`-cursor poll is sufficient and simpler.
- **Expose the `outbox` payload / node keys directly on the feed.** Rejected — the
  outbox has no scope column and its payload can carry private strings; the feed
  emits only scope-resolved typed fields and drops out-of-scope events.
- **A single generic "introspect" RPC for all three surfaces.** Rejected —
  conflates three different shapes, scope rules, and lifecycles (a live answer
  artifact vs a graph projection vs an append-only event log) behind one untyped
  contract; three typed RPCs keep each scope-enforceable and renderable verbatim.
