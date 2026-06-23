# ADR-4: Graph schema is a versioned, write-validated public contract

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`. This hardens the *shared data schema* that typed ports
(`../../../docs/architecture/ports.md`) do not protect.

## Status

Accepted (built and validated — see `../design/graph-integrity-contract.md`)

## Record Completeness

Complete

## Context

The graph is Swarm's shared memory, answer surface, coordination medium,
confidence substrate, **and** the plugin exchange format — all at once. Typed
ports protect the *call* boundary; they do **not** protect the *shared data
schema*. Today a plugin or worker can corrupt or misread the common substrate
while still "obeying typed ports" (N2, Codex's biggest unnamed risk):

- **Edge writes are unvalidated.** `Swarm.Graph.Store.add_edge` is raw SQL with no
  schema check; `type` and `visibility_scope` are free strings.
- **The ADR-5 (workspace) visibility invariant is enforced by one caller, not the
  boundary.** "An edge's scope ≤ the narrowest of its two endpoints" is computed
  inside `Swarm.Ingest` (`narrowest/2`) only. A direct
  `Store.add_edge(src, dst, type, prov, scope: "public")` between two `private`
  nodes bypasses it — a silent visibility leak, the security-critical corruption
  path.
- **No graph schema version.** `schema_meta` versions the *embedding* namespace
  (ADR-6), not the node/edge schema, so there is no migration-compatibility anchor.

Discovered late, this silently poisons everything downstream (confidence, answers,
coordination). It must be a contract enforced at the write boundary, before broad
plugin/channel expansion (T4, T9).

## Decision

The graph schema is a **public kernel contract, validated at every write**, with a
**version stamp** and a **migration/compatibility policy**.

1. **One validation point: `Swarm.Graph.Contract`.** Every write through
   `Swarm.Graph.Store` (`add_node`, `add_edge`, `upsert_node`) is validated
   against it. Violations are **rejected fail-loud** (`{:error, reason}`), never
   silently stored. Plugins reach the graph through kernel APIs, so the Store
   boundary is the contract boundary; the scope **vocabulary** is *additionally*
   enforced by a DB `CHECK` (defense-in-depth against any non-Store writer). The
   cross-row *visibility invariant* (point 3) cannot be a `CHECK` (it references
   other rows), so it stays an app-boundary check with a DB trigger deferred (see
   Alternatives).

2. **Scope is a closed, ordered vocabulary.** `private < group < public` (the
   existing `Ingest` ranking, promoted to the contract). A write with a scope
   outside the set is rejected.

3. **The visibility invariant is enforced at the boundary, not by callers.**
   `add_edge` looks up both endpoint scopes and rejects any edge whose scope is
   **wider** than the narrowest endpoint (`rank(edge) ≤ min(rank(src),
   rank(dst))`). Well-behaved callers (`Ingest`) already compute the narrowest
   scope, so they pass; a caller asserting a wider scope is rejected. This moves
   the ADR-5 (workspace) guarantee from convention into the kernel. The endpoint
   read takes `FOR SHARE` so a concurrent re-scope cannot widen an endpoint
   between the check and the insert (closes the read-then-write TOCTOU window).
   The invariant is enforced at **edge-write time only** — see Consequences for
   the residual gap.

   **Provenance — shape only.** Edge provenance must be present and non-blank
   (the ADR-9 reinforcement-guard key). Whether a provenance key tracks
   *evidential origin* rather than *emission instance* — the independence hazard —
   is the **separate open decision** in ADR-9 / `confidence-calculus.md`, NOT
   settled here. T2 does not claim provenance-lineage integrity.

4. **Type is structurally validated, not yet a closed enum.** `type` must be a
   non-empty lowercase identifier. The node/edge **type vocabulary is a versioned
   registry** that today admits any well-formed type (the system is early; tests
   use free types) and tightens by *raising the schema version* via migration —
   not by silent drift. Closing the enum is a future version bump, recorded here
   as the extension path.

5. **Reliability stays in `[0, 1]`** (already a DB check + Node changeset);
   centralized in the contract so edges (raw SQL) are covered too.

6. **Schema version is stamped and queryable.** A singleton `graph_schema_meta`
   row carries the integer graph-schema version; `Contract.stamped_version/0`
   reads it and it mirrors the compiled `schema_version/0`. The **policy**: every
   schema change ships a migration that bumps the version **and** adds a round-trip
   test proving data written at vN still reads at vN+1. At v1 there is no prior
   version, so what exists today is the stamp + an intra-version read-back test;
   the cross-version round-trip is exercised at the **first bump** (the policy is
   in place, not yet demonstrated).

## Consequences

- The silent visibility-leak path is closed: a too-wide edge scope is rejected at
  the Store boundary, so the ADR-5 read filter rests on a guaranteed write
  invariant rather than caller discipline.
- Edge writes pay two indexed endpoint-scope lookups inside the existing
  transaction — O(1), no scans (the Store performance invariant holds).
- Malformed shared state fails loud at the writer instead of poisoning readers
  later; the error names the violated rule.
- `Ingest` is unchanged behaviourally (it already computes narrowest) but is now
  *backed* by the contract rather than being the sole enforcer.
- The type vocabulary is honest about being open today; tightening is a versioned,
  tested migration, never a silent change.
- **Residual gap — the invariant is write-time-only.** It is checked when an edge
  is written (with `FOR SHARE` closing the concurrent-widen race). It is **not**
  re-checked if an endpoint node is *later re-scoped narrower* — existing edges
  would keep a now-too-wide `visibility_scope`. Today there is **no node-re-scope
  code path** (`add_node` inserts; `upsert_node`'s `ON CONFLICT` touches only
  `updated_at`; coordination touches only claim/lease), so the window is empty by
  construction. But any future "promote/demote node scope" operation **must**
  either re-validate/cascade affected edges or be paired with the DB trigger
  below — this is a tracked precondition, not a closed hole. The read filter
  (`gate/visibility.ex`) independently checks both node and edge scope (fail-safe),
  so a stale-wide edge still cannot disclose a narrowed *node*; the write
  invariant is belt-and-suspenders, not the read side's sole guard.

## Alternatives

- **Clamp a too-wide edge scope to the narrowest endpoint** (what `Ingest` does
  internally). Rejected as the *boundary* rule — silently rewriting a caller's
  asserted scope hides a bug; fail-loud surfaces it. `Ingest` may still compute
  the correct scope before calling; the contract rejects only an *asserted* wider
  scope.
- **Close the node/edge type enum now.** Rejected — premature; the system is early
  and types are used freely. A closed enum is a future version bump with its own
  migration + test, recorded as the extension path here.
- **Enforce only via a DB trigger / CHECK.** Deferred as *defense-in-depth*, not
  the primary mechanism — a cross-row trigger is more invasive to evolve and
  test, and all writes already funnel through `Store`. The app-level contract is
  primary; a trigger mirror can be added later for raw-SQL paths.
- **A per-row schema-version stamp.** Rejected — the schema version is a property
  of the whole graph schema, not each row; a singleton meta row is queryable and
  enough for the migration-compatibility anchor.
