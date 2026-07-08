---
status: proposed
adr: workspace ADR-18 (per-source scope + first-class groups)
evolves: workspace ADR-16 (users/identity/privacy) — access mechanism only
council: required before execution (2-family; forks F1-F4 in ADR-18)
---

# Per-source scope + first-class groups (kernel design spec)

How ADR-18 lands in the `swarm/` kernel. The identity anchor, verified-actor assertion (D9),
and per-user conversation privacy from `users-identity-privacy.md` are UNCHANGED; this spec
only evolves the **scope** substrate and the **group/role** model. Mechanism forks (F1-F4)
are settled by the execution council first; this spec is the shape to implement against.

## 1. Scope substrate

- **Value space.** `Swarm.Graph.Contract`: the scope enum
  `{private, group, public}` → `{private, public, src:<name>…}`. `private` and `public` keep
  their semantics (ungrantable / universal baseline). `group` is retired — every `group` node
  is migrated to a `src:<name>` (§4). The open `src:*` namespace is validated by shape
  (`^src:[a-z0-9_-]+$`), not a fixed list.
- **Ordering (F1).** Replace the total-order `@scope_rank` clamp with: `private` = floor 0,
  `public` = ceiling, each `src:*` an incomparable mid-band tag. A node carries exactly ONE
  scope (its origin's `src`, or `public`/`private`). The ingest "clamp" becomes: a node's scope
  = its origin's `src` unless explicitly `public`/`private`. Visibility at read = set-membership
  (`node.scope = ANY(viewer_scopes)`), NOT rank comparison.
- **Derivation.** A node's `src` scope is a pure function of its ingest origin —
  `origin_to_src(origin)` (e.g. `wiki:page:… → src:wiki`, `iac:<repo> → src:iac`,
  `ldap:directory → src:ldap`, `confluence:… → src:confluence`). One table/function, single
  source of truth, used by connectors at write time and by the migration.

## 2. Viewer scopes

- `Identity.scopes_for/1`: `["public"] ∪ (SELECT unnest(scopes) FROM group_scope_map JOIN
  user_group …)` where `group_scope_map.scopes` now holds `src:*` values. Default-deny
  preserved: no group ⇒ `["public"]`. `private` never enters a wire scope list
  (`Core.Auth` clamp unchanged).
- The **authenticated⇒public baseline** (F4) is explicit and tested — a signed actor with no
  group still derives `["public"]`, never `[]`.

## 3. Predicate rewrite (the invariant)

Every scope predicate site (`retrieval`, `traverse`, `neighborhood`, `aggregation`,
`corroboration`, `procedure`, `who_map`, `network`, `synonymy`, `activity`, `gate/visibility`)
already filters `scope = ANY($scopes)` — the change is data (the value space), not shape, so the
predicates keep working IF F1's set-membership semantics hold. Audit each site for any residual
**rank assumption** (`min`/`<`/`>` on scope) and replace with membership. `edge` + BOTH
endpoints on every hop stays mandatory. Multi-origin nodes (F3): a node's stored scope follows
the council's F3 rule (union-of-sources vs most-restrictive) applied in the corroboration/merge
path so corroboration can never silently widen visibility.

## 4. Migration (reversible)

- Snapshot first. `20260709_per_source_scope.exs`: for every node/edge with `scope='group'`,
  set `scope = origin_to_src(edge_provenance.origin)`; nodes with no origin default to the most
  restrictive non-public `src` (or flagged for review, not silently public). `group_scope_map`
  rows rewritten from `group` to the src-set the group should grant (from the initial config).
  Down-migration maps `src:*` back to `group` (reversible parity — verified by round-trip).
- No node silently becomes `public`. Positive-control verify (F4): an `Everyone` persona sees
  `src:wiki`/`src:ldap` hits and **0** on `src:confluence`/`src:iac`/`src:network`.

## 5. Groups first-class + group→role

- Migration: `group {id, name, description, created_at}`; backfill ids from existing
  `user_group`+`group_scope_map`. Id stability decided in ADR (slug vs uuid) — SSO mapping keys
  on it. `group_role {group_id, role}`.
- `roles_for/1` (and thus `caps_for/1`) = `DISTINCT(role_grant ∪ group_role via user_group)`.
  Default-deny: no binding ⇒ no role.
- `Admin` ops (cap-gated + audited): create/rename/delete group (delete cascades
  `user_group`+`group_scope_map`+`group_role`, explicit confirm on non-empty); set/clear a
  group's role; set a group's `src` scopes (extends `set_group_scopes`, grant-boundary =
  `src:*` shape ∪ never `private`).

## 6. SSO claim mappers

- Config (store decided in ADR — kernel table vs channel settings): which claim carries
  groups/roles (defaults `groups`, `realm_access.roles`; today hardcoded in
  `auth.principal_from_claims`), and an `incoming-group → our-group` map (evolves
  `GROUP_SCOPE_MAP`). `upsert_from_claims`/`provision_from_claims` apply it at login to set
  `user_group` (which now confers src-scopes AND role via §2/§5). Unmapped incoming group ⇒
  nothing.

## 7. RPC deltas

- `ListGroups.granted_roles` (left empty by the read card) now populates.
- New: `ManageGroup` (create/rename/delete/set-role/set-scopes) OR extend `ManageAccess` —
  wire-shape decided in ADR. proto stubs regenerated for the connector.

## 8. Test plan (the no-leak-class gate)

- Membership: `Everyone` persona → `src:wiki`/`src:ldap` visible, `src:confluence`/`src:iac`/
  `src:network` → 0 (positive controls, not just empties).
- Group→role: a user gains admin via group membership ALONE (no direct grant).
- SSO: an incoming Keycloak group maps → our group → its scopes+role; an unmapped group grants
  nothing.
- Migration round-trip: up then down reproduces the pre-migration scope distribution exactly.
- RLS live under the non-superuser role; the adversarial no-leak ship gate re-run green.
- Real-path (not stub) entail for the who/network serve under the new scopes (a stub masks
  Stage-2 vetoes — memory `verify-real-serve-path-not-stub-entail`).
