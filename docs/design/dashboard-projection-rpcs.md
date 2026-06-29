---
status: proposed
implements: "swarm ADR-15 (Proposed) — ../decisions/0015-dashboard-projection-rpcs.md"
owner: swarm
---

# Spec: Dashboard projection RPCs — deliberation / neighborhood / activity

The decided wire contracts for the "how the swarm thinks" dashboard. Three
read-only, scope-enforcing, viewer-aware Core RPCs over `swarm.core.v1`. This spec
says *what to build* precisely enough to implement against; it does **not**
authorise building it (that is the gated kernel phase). Implements swarm ADR-15.

## Conventions (inherited, not re-decided)

- Every request carries `repeated string scopes` (field with the same meaning as
  `AskRequest.scopes`: default-deny, empty ⇒ `["public"]` at the server edge) and
  `string viewer` (ADR-7: opaque canonical id; the channel maps the platform user).
- The **kernel enforces** scope; the channel passes an authenticated identity only.
- Every response carries `AnswerStatus status` (ADR-6): `FOUND` / `NOT_FOUND` /
  `ERROR`. **`PARTIAL` is unused** by these RPCs; bounded/incomplete results are
  signalled by an explicit `truncated` flag (Neighborhood), never by overloading
  `PARTIAL`. A `NOT_FOUND` must be **timing-indistinguishable** from an
  out-of-scope/absent case (don't leak existence via latency).
- Fields are ids / typed values rendered **verbatim** by the channel (T7) — no
  prose, no raw DB row, no payload blob crosses the wire.
- **Wire-type choices are deliberately consistent with the shipped contract**, not
  re-litigated: timestamps are `string` ISO-8601 (matching `StatusResponse.last_activity`)
  and scopes/relation-filters are `repeated string` (matching `AskRequest.scopes`) —
  not `google.protobuf.Timestamp` / a new enum. Unknown scope strings are
  default-deny; `kinds` is matched against the kernel's closed event-kind set
  (unknown ⇒ matches nothing); `relation_types` filters the **open** edge-type
  vocabulary (unknown ⇒ matches nothing, never an error).
- Field numbers below are the proposed additive shapes; `buf`/`protoc` validity in
  shape is a done-condition (this spec proposes text only — no regen this phase).

## RPC 1 — `Deliberation` (panel-vs-judge, retained, viewer-owned)

```protobuf
service Core {
  // ... existing Ask / KbStatus / KbSearch ...
  // The panel-vs-judge deliberation behind a past escalated answer, by ask_ref.
  rpc Deliberation(DeliberationRequest) returns (DeliberationResponse);
}

message DeliberationRequest {
  string ask_ref = 1;            // minted by the kernel on escalation; from AskResponse.ask_ref
  repeated string scopes = 2;
  string viewer = 3;
}

message PanelTake {
  string model = 1;              // panel model name (e.g. "lfm2.5:8b")
  string answer = 2;             // that model's raw take (verbatim)
}

message DeliberationResponse {
  AnswerStatus status = 1;       // FOUND | NOT_FOUND (unknown/expired/not-owner) | ERROR
  string ask_ref = 2;
  string answer = 3;             // the judge's synthesized answer (mirrors the post)
  double confidence = 4;
  double disagreement = 5;       // mean pairwise panel distance [0,1] (a confidence signal, ADR-7)
  repeated PanelTake panel = 6;  // the raw takes before synthesis
  string judge = 7;              // judge model name
  string created_at = 8;         // ISO-8601 (when the deliberation ran)
}
```

- **Source**: the `Consilium.deliberate/2` verdict
  (`%{answer, confidence, disagreement, panel: [%{model, answer}], judge}`),
  persisted on escalation (it is discarded today — that is the change).
- **`ask_ref`**: an **opaque, high-entropy, kernel-minted** token (e.g. a UUID/random
  id) — **not** a guessable/enumerable sequence. The channel treats it as opaque.
- **Minting + retention**: on an escalation **with a non-empty viewer**, the kernel
  mints `ask_ref`, persists `{ask_ref, viewer, effective_scope, answer, confidence,
  disagreement, panel, judge, created_at}`, and returns `ask_ref` on `AskResponse`.
  `effective_scope` is the scope the retrieval ran under (the asking scopes).
  Anonymous escalations are **not** retained (`ask_ref` empty). Persist is a single
  insert **after** `deliberate/2` returns (never holds a connection across the LLM).
- **Retention/GC**: bounded by a configurable TTL + a max-row cap, GC'd via the
  ADR-10 decay-driven trace lifecycle. (Policy values live in config, not here.)
- **Scope/viewer enforcement (the no-leak rule)**: the row is returned **only** when
  **both** (a) the requesting `viewer` matches the owning asker, **and** (b) the
  request's current `scopes` still **cover** the stored `effective_scope`. Owner-
  match alone is insufficient: a viewer who has since *lost* a scope must not
  re-open a deliberation derived under it (no stale-authorization bypass — a council
  finding). Any failure — mismatched viewer, current scopes that no longer cover,
  or an unknown/expired `ask_ref` — ⇒ `NOT_FOUND` (existence never revealed),
  timing-uniform.

## RPC 2 — `Neighborhood` (bounded, scoped graph connections)

```protobuf
service Core {
  // A bounded, scope-filtered neighborhood around one node: nodes + typed edges.
  rpc Neighborhood(NeighborhoodRequest) returns (NeighborhoodResponse);
}

message NeighborhoodRequest {
  int64 node_id = 1;                 // the center (e.g. from a SearchHit.id)
  uint32 depth = 2;                  // hops; clamped to [1,2]; 0 ⇒ default 1
  uint32 node_limit = 3;             // max nodes returned; clamped to [1,50]; 0 ⇒ default 50
  repeated string relation_types = 4;// edge-type filter; empty ⇒ all types
  repeated string scopes = 5;
  string viewer = 6;
}

message NodeView {
  int64 id = 1;
  string type = 2;                   // kernel node type (closed vocab)
  string key = 3;                    // identity key (verbatim)
  string scope = 4;                  // the node's own scope (always within request scopes)
  double confidence = 5;             // best-path confidence from the center (Traverse)
  uint32 depth = 6;                  // min hop-distance from the center
}

message EdgeView {
  int64 src_id = 1;
  int64 dst_id = 2;
  string relation = 3;               // edge type (e.g. "child_of", "mentions")
  double reliability = 4;            // edge reliability [0,1]
}

message NeighborhoodResponse {
  AnswerStatus status = 1;           // FOUND | NOT_FOUND (center not visible/absent) | ERROR
  int64 center_id = 2;
  repeated NodeView nodes = 3;       // excludes the center; sorted by confidence desc
  repeated EdgeView edges = 4;       // only edges between returned (in-scope) nodes
  bool truncated = 5;                // node_limit or ADR-3 edge-budget hit (best-effort)
}
```

- **Mechanism**: reuse `Traverse.walk/3` with `:scopes` (scope-enforced on both
  `node.scope` and `edge.visibility_scope`; refuted `reward<0` edges excluded) to
  get the reachable in-scope node ids, then **hydrate** `NodeView` (`id, type, key,
  scope, confidence, depth`) and **project** the `EdgeView`s among the returned
  nodes (scope-filtered, `relation_types`-filtered). `walk/3` returns ids only —
  node hydration and edge projection are the new work (a thin `Graph.Neighborhood`
  projection), bounded.
- **Bounds (by contract, clamped kernel-side)**: `depth ∈ [1,2]`, `node_limit ∈
  [1,50]`, optional `relation_types`. The full hairball is unreachable by
  construction; `truncated` is surfaced when a bound or the ADR-3 edge budget bites
  (it is the authoritative completeness signal — status stays `FOUND`).
- **Deterministic ordering**: `nodes` sorted by `confidence` desc then `id` asc;
  `edges` by `(src_id, dst_id, relation)`. So the same request renders identically
  (presentation determinism).
- **Scope/viewer enforcement (the no-leak rule)**: the center must be visible to
  the request `scopes` or ⇒ `NOT_FOUND` (don't reveal a hidden node's existence;
  timing-uniform with an absent id). Every `NodeView.scope` is within the request
  scopes. An edge appears only when **all three** hold: its **own**
  `visibility_scope` ∈ request scopes (an edge can be private between two visible
  nodes — endpoint-visibility alone is insufficient; a council finding), **and**
  both endpoints are in the returned in-scope set. This matches the existing
  `Traverse` edge query (`e.visibility_scope = ANY($2) AND n.scope = ANY($2)`).
  `key` is returned only for an in-scope (already-authorized) node — the same datum
  `KbSearch` already returns for an in-scope hit, rendered as the connection label.
  `viewer` is carried for owner-narrowing parity but scope is the boundary (ADR-7).

## RPC 3 — `ActivityFeed` (poll, scope-safe job events)

```protobuf
service Core {
  // Worker/job activity as a polled, scope-safe typed event log (opaque cursor).
  rpc ActivityFeed(ActivityFeedRequest) returns (ActivityFeedResponse);
}

message ActivityFeedRequest {
  string cursor = 1;                 // opaque resume token from a prior next_cursor; "" ⇒ most recent
  uint32 limit = 2;                  // clamped to [1,100]; 0 ⇒ default 50
  repeated string kinds = 3;         // event-kind filter (closed set); empty ⇒ all kinds
  repeated string scopes = 4;
  string viewer = 5;
}

message ActivityEvent {
  string kind = 1;                   // e.g. "node_created" | "edge_added" | "enrichment" | "entity_resolution"
  string at = 2;                     // ISO-8601
  string subject_type = 3;           // referenced node type (scope-gated, in-scope only); "" if none
  string outcome = 4;                // typed outcome (e.g. "merged" | "rejected" | "enriched" | "skipped"); "" if n/a
  int64 count = 5;                   // typed count of IN-SCOPE subjects only (e.g. claims written); 0 if n/a
}

message ActivityFeedResponse {
  AnswerStatus status = 1;           // FOUND | NOT_FOUND (no visible events) | ERROR
  repeated ActivityEvent events = 2; // already scope-filtered; ordered oldest→newest within the page
  string next_cursor = 3;            // opaque token to pass as the next request.cursor
}
```

- **Sources**: `outbox` (`seq, change, target_key, inserted_at`) for the thin
  dispatch slice available now; `entity_resolution_audit` and
  `enrichment_decision`/`enrichment_pass` for rich outcomes **when the loop runs**.
  Each maps to one `ActivityEvent` with only the scope-safe typed fields above.
- **Poll, not stream**: the channel polls with an **opaque `cursor`**; `next_cursor`
  resumes. No server-streaming RPC, no raw sequence number on the wire.
- **Opaque cursor — the gap-leak fix (council headline)**: the wire carries **no
  raw global `seq`**. The kernel encodes its internal position inside the opaque
  `cursor`/`next_cursor` and, per poll, **scans forward server-side past
  filtered-out (out-of-scope) events** (bounded by an internal scan budget) so the
  client sees only visible events and **cannot infer hidden-event volume or timing
  from sequence gaps** — the single most important fix both critics named. The scan
  is bounded; if the budget is hit before `limit` visible events accrue, the page
  returns short with a `next_cursor` that resumes mid-range (no unbounded work, no
  gap disclosure).
- **Scope/viewer enforcement (the no-leak rule)**: the **raw `payload`,
  `target_key`, and node `key` are never emitted**. The kernel resolves each event's
  referenced node scope (join `target_key`/`node_id` → `node.scope`) and **drops**
  any event whose subject is outside the request scopes — no redacted placeholder
  (that would leak private-activity volume). `subject_type` is emitted only for an
  in-scope subject; `count` aggregates **only in-scope subjects** (never a raw
  outbox/audit count that would disclose private volume). Events with no node
  subject (pure pass summaries) carry aggregate counts only.

## Done-conditions (per the verification standard)

The design's external signal this phase is the **council verdict + `review-step`**
on this spec and ADR-15; the proto text must stay **`buf`/`protoc`-valid in shape**.
Each build card (next phase) inherits a concrete no-leak gate:

| Contract | No-leak / correctness done-condition |
| --- | --- |
| `Deliberation` | A non-owner `viewer`, current scopes that no longer cover the stored `effective_scope`, or an empty/unknown/expired (opaque) `ask_ref` ⇒ `NOT_FOUND` (timing-uniform), never the panel; anonymous escalation persists nothing; TTL+cap GC verified; persist holds no connection across the LLM. |
| `Neighborhood` | Out-of-scope center ⇒ `NOT_FOUND` (timing-uniform); no `NodeView` outside request scopes; an edge appears only if its **own** `visibility_scope` ∈ scopes **and** both endpoints are returned; `depth>2`/`node_limit>50` clamped; a dense hub returns `truncated`, never a hairball; deterministic order; ids/types/keys rendered verbatim. |
| `ActivityFeed` | No `payload`/`target_key`/`key`/raw `seq` on the wire; an event whose subject node is out of scope is absent for that viewer and **invisible-event volume/timing is not inferable from cursor gaps** (opaque cursor + bounded server-side skip); `count` is in-scope-only; thin slice present now, rich outcomes appear only when the loop runs. |

## Limitations (honest scope)

- **`ActivityFeed` rich content is loop-gated.** With the loop off, the feed is the
  thin outbox dispatch slice (ingest node/edge writes); ER/enrichment outcomes
  appear only once those workers run. The contract is ready; the content follows.
- **Deliberation retention is new, partly-irreversible state.** The TTL/cap and the
  ADR-10 GC reuse bound it, but a retention policy is a real commitment — it is the
  decision the council is asked to weigh hardest.
- **`Neighborhood` confidence/depth come from `Traverse`** (best-path confidence,
  min depth); it is an observability projection, not a new traversal semantics.
- **Design-only.** No kernel code, no proto regen, no channel work in this phase.
