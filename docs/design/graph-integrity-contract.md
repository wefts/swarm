---
status: built
implements: "swarm ADR-4 (Accepted) — ../decisions/0004-graph-integrity-contract.md"
owner: swarm
---

# Spec: Graph integrity contract (T2)

How the shared graph schema is validated at the write boundary so a plugin or
worker cannot corrupt or misread the common substrate while "obeying typed
ports." Implements swarm ADR-4. Sits at `Swarm.Graph.Store`; complements the
*call*-boundary protection of `../../../docs/architecture/ports.md`.

## The contract — `Swarm.Graph.Contract`

The single validation point. Every write through `Swarm.Graph.Store` routes
through it; violations are rejected fail-loud, never silently stored.

| Rule | Check | On violation |
| --- | --- | --- |
| Scope vocabulary | `scope ∈ {private, group, public}` | `{:error, :unknown_scope}` |
| Type shape | `type` matches `^[a-z][a-z0-9_]*$` | `:invalid_type_format` / `:missing_type` |
| Reliability | `0 ≤ r ≤ 1` | `:reliability_out_of_range` |
| Provenance shape | edge provenance present, non-blank | `:blank_provenance` |
| Endpoints exist | both edge endpoints resolve to a scope | `:unknown_endpoint` |
| **Visibility invariant** | `rank(edge) ≤ min(rank(src), rank(dst))`, `private<group<public` | `:scope_wider_than_endpoints` |

## Enforcement points (defense in depth)

- **App boundary (primary).** `Store.add_node` validates via the `Node` changeset
  (scope inclusion + type format); `Store.add_edge` looks up both endpoint scopes
  (`SELECT … FOR SHARE`) and calls `Contract.validate_edge/6`, rolling back
  `{:contract, reason}` on violation; `Store.upsert_node` validates and raises
  `ArgumentError` fail-loud (it is the raw-SQL ingest path with no changeset).
- **DB (defense in depth).** A `CHECK` constraint pins the scope **vocabulary** on
  `node.scope` and `edge.visibility_scope`, so a non-`Store` writer (raw SQL,
  psql, a plugin with DB creds) still cannot insert an out-of-vocabulary scope.
- **TOCTOU.** The endpoint read takes `FOR SHARE`, so a concurrent re-scope cannot
  widen an endpoint between the check and the insert.

The cross-row **visibility invariant** cannot be a `CHECK` (it references other
rows). It is the app-boundary check today; a DB trigger is the deferred
defense-in-depth mirror (see Limitations).

## Schema version

`graph_schema_meta` is a singleton row (`id=1, version=1`) stamped by migration
`20260623140000`. `Contract.stamped_version/0` reads it; `Contract.schema_version/0`
is the compiled mirror. **Policy:** every node/edge schema change bumps the version
in a migration and adds a vN→vN+1 round-trip test. At v1 only the stamp + an
intra-version read-back exist; the cross-version round-trip is exercised at the
first bump.

## Limitations (honest scope; tracked follow-ups)

- **Write-time-only invariant.** The visibility invariant is checked at edge
  write. It is **not** re-checked if an endpoint node is later re-scoped narrower.
  Today no node-re-scope code path exists, so the window is empty; any future
  re-scope operation must re-validate/cascade affected edges or land with the DB
  trigger. Tracked: `board/todo/graph-rescope-and-trigger`.
- **Provenance is shape-only.** Non-blank is enforced; *evidential-origin*
  lineage (the independence hazard) stays the open decision in ADR-9 /
  `confidence-calculus.md`, not claimed here.
- **Type vocabulary is open** (well-formed but unrestricted); closing it is a
  future versioned migration.

## Acceptance (external signal)

- A test proves an asserted wider-than-endpoints edge is **rejected and not
  stored** (`edge_count == 0` after a rolled-back tx) — the leak path is closed.
- DB-`CHECK` test: a raw-SQL out-of-vocabulary scope is rejected by Postgres.
- Schema version is stamped and queryable.
- `mix test` 87/0; credo `--strict` clean; dialyzer 0; format clean.

## Verification

Independent critic (different family) reviewed the contract and visibility story
and returned SOUND-WITH-CAVEATS; its caveats (TOCTOU, write-time-only durability,
provenance scope, vN→vN+1 testability) were applied as the `FOR SHARE` lock, the
DB `CHECK`, the documented re-scope follow-up, and the honest version-policy
wording above. Codex critic unavailable (bwrap netns blocked on this host).
