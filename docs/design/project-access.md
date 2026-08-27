---
status: accepted (design council 2026-08-27: codex FLAWED→fixed, gemini FLAWED→fixed; verdicts folded in §13)
adr: workspace ADR-20 (project access + wheel elevation)
evolves: users-identity-privacy.md (substrate kept), per-source-scope-authz.md (direct group grants superseded)
council: required before the migration + elevation land (2-family; see board/research/project-access-blackboard.md)
---

# Project-centered access + Wheel elevation (kernel design spec)

How workspace **ADR-20** lands in the `swarm/` kernel. The ADR-16 substrate is UNCHANGED: signed
actor assertion (D9), kernel-derived `{uuid, scopes, caps}`, `scope × owner`, one gate,
default-deny, RLS belt on owned rows, break-glass through the same filtered path. What changes
is **where effective source scopes come from** (Project membership, not group grants), **what
the source scope key is** (`src:<source_uuid>`, not a global label), **which groups exist**
(`wheel` / `admins` / `staff`, fixed) and **how superadmin exists** (a time-boxed elevation, not
a standing role). Readable canon: `docs/architecture/access-model.md` (workspace).

## 1. Ownership split (unchanged)

- **Kernel (`swarm/`)** owns Projects, Sources, memberships, groups, roles, elevation, the scope
  derivation and every read gate. It is the sole authority.
- **Channel (`hive/web_channel`)** owns authentication only (password / OIDC / sessions) and
  signs actor assertions. For elevation it additionally signs a **re-authentication proof**
  (§5) after re-verifying the local password. It never decides scopes or capabilities: the
  channel's `Principal.scopes` are what `ResolveActor` returned, nothing else.

## 2. Data model (kernel, auxiliary tables — no graph-schema bump for the tables themselves)

```text
project             (id uuid PK, name text NOT NULL, description text,
                     visibility text NOT NULL CHECK IN ('personal','shared','public') DEFAULT 'shared',
                     created_by uuid NULL, created_at, updated_at)
source              (id uuid PK, project_id uuid FK→project ON DELETE CASCADE,
                     kind text NOT NULL,            -- label/routing hint: wiki | confluence | ldap | iac | legacy | …
                     label text NOT NULL,           -- human label, NOT a security key
                     origin text NOT NULL CHECK IN ('migration','admin') DEFAULT 'admin',
                     created_at)                    -- scope key = 'src:' || id::text
                     -- NO owner_id column yet: a personal connector needs the graph owner axis (§9);
                     -- reserving a column the read gate cannot enforce would be a false coordinate (council: codex)
project_membership  (project_id uuid FK→project ON DELETE CASCADE,
                     user_id uuid NULL FK→app_user ON DELETE CASCADE,
                     group_id text NULL FK→access_group ON DELETE CASCADE,
                     role text NOT NULL CHECK IN ('owner','member') DEFAULT 'member',
                     source text NOT NULL CHECK IN ('local','migration') DEFAULT 'local',
                     granted_by uuid NULL, created_at,
                     CHECK ((user_id IS NULL) <> (group_id IS NULL)),
                     UNIQUE (project_id, user_id), UNIQUE (project_id, group_id))
elevation           (id uuid PK, user_id uuid FK→app_user, reason text NOT NULL,
                     sid text NOT NULL,             -- the SESSION the elevation is bound to (council: codex)
                     reauth_jti text NOT NULL UNIQUE, -- one-time re-auth proof id (council: gemini — replay)
                     created_at, expires_at timestamptz NOT NULL, revoked_at timestamptz NULL)
app_user            + external boolean NOT NULL DEFAULT false   -- guest flag (ADR-20 Guests)
access_group        fixed rows: wheel ('Wheel'), admins ('Admins'), staff ('Staff'); CREATE/DELETE rejected
group_role          CHECK role IN ('admin')  -- 'superadmin' is no longer a bindable role
role_grant          DROPPED (ADR-19 already emptied it; per-user roles are gone)
group_scope_map     DROPPED (groups never grant source visibility)
```

Invariants carried by the schema: `project_membership` is the ONLY path to a source scope
(I4); `group_role` has no `superadmin` row (I5 — superadmin exists only in `elevation`);
`elevation.user_id` is checked at request time for `wheel` membership + `provider = local`
(I6); the node/edge CHECK admits only `private | public | src:<uuid>` (I1 belt).

## 3. Scope vocabulary (graph substrate)

- Value space: `{private, public, src:<uuid>}`. `group` is **retired** (the migration re-homes
  any remaining `group` rows, §10). `Contract.valid_scope?/1` accepts the closed base vocab OR a
  well-formed `src:` + lowercase hyphenated UUID; the node/edge CHECK constraints are tightened
  to the same regex. The `chunk.scope` mirror needs no change (trigger-maintained from `node`).
- Lattice unchanged: `private` = ⊥, `public` = ⊤, each `src:<uuid>` an incomparable mid-band
  tag; edge scope = GLB of its endpoints; cross-source edge ⇒ `private` (ADR-18 F1/F3).
- `Contract.origin_to_src/1` is **removed**: an ingest origin label (`wiki:…`, `confluence:…`)
  is no longer a security key. What remains is `Contract.derived_origin?/1` (`enrich:` /
  `synonymy:` ⇒ the derived fact inherits its anchor node's scope — unchanged rule).
- **Ingest boundary check (new, fail-loud):** an entity whose scope is `src:*` must name a
  REGISTERED source (`Swarm.Projects.registered_scope?/1`); otherwise the event is quarantined
  (`{:unregistered_source_scope, scope}`). Through the connector boundary (`Swarm.Ingest`) a row
  can never be written under a scope nobody can derive. The lower-level `Store.upsert_node` /
  `Graph.add_node` validate SHAPE only (`src:<uuid>`) — kernel enrichers reach them with an
  inherited anchor scope, operator loaders with `Swarm.Projects.scope!/1`; that discipline (not
  a registry lookup) is what keeps direct writes honest.
- Connectors and operator loaders obtain their scope from the registry — `Swarm.Projects.scope!(source_id)`
  (or the loader convenience `Swarm.Projects.scope_by_kind!(kind)`, which raises when 0 or >1 sources
  of that kind exist — ambiguity is resolved by id, never guessed). **Kernel enrichers never choose a
  scope**: every derived write (worker, procedures, network map, who map) inherits the ANCHOR node's
  scope by API shape (council: codex). `WhoMap` stops computing a global `src:ldap` — it writes at
  `anchor.scope`, which the loader set from the registered LDAP Source.
- **Accepted limitation (carded):** the registered-scope check stops INVENTED scopes; it does not
  prove the writer is the connector assigned to that Source — connectors have no service identity
  at all today (ADR-16 "service/agent identity" gap). Binding ingest to a connector credential is
  the `connector-service-identity` card, not this epic.

## 4. Effective scopes (the derivation `Swarm.Actor.resolve/2` hands to every gate)

```sql
-- Swarm.Projects.effective_scopes(user_id) — 'public' is prepended by the caller (the authenticated floor)
SELECT DISTINCT 'src:' || s.id::text
  FROM source s
  JOIN project p ON p.id = s.project_id
 WHERE ($1::uuid IS NOT NULL AND p.visibility = 'public')                  -- baseline material, AUTHENTICATED only (council: gemini)
    OR EXISTS (SELECT 1 FROM project_membership pm
                WHERE pm.project_id = p.id AND pm.user_id = $1)             -- direct, audited membership
    OR EXISTS (SELECT 1 FROM project_membership pm
                JOIN user_group ug ON ug.group_id = pm.group_id
                WHERE pm.project_id = p.id AND ug.user_id = $1)             -- via a group member
```

`scopes_for(user) = ["public"] ∪ effective_scopes(user)`, `private` never enters (unchanged clamp);
`effective_scopes(nil)` is `[]` by function clause — an anonymous actor can never reach the query.
No group, no membership ⇒ exactly `["public"]`. The anonymous/legacy path stays `["public"]`
(`Core.Auth.norm_scopes/1`) — public **Projects** are visible to authenticated actors only; the
literal `public` graph scope remains the anonymous floor for genuinely public material (marker
nodes, public corpora). `SWARM_AUTH_BASELINE_GROUP` and `Identity.baseline_scopes/0` are removed:
the "everyone sees the internal wiki" behaviour becomes an explicit, audited fact — the
`staff` group is a member of the `Internal` Project (§10).

## 5. Roles, capabilities, elevation

```text
role admin      (bound to group `admins` by default; `manage_roles` may bind it to another fixed group)
  caps: manage_access, invite_users, manage_users, manage_projects
role superadmin (NOT bindable; present iff the actor has an ACTIVE elevation)
  caps: all admin caps + read_any_conversation, manage_wheel, manage_roles, manage_auth, manage_publicness
```

`Identity.roles_for/1` takes an **actor ref** — a bare `uuid` (never elevated) or `{uuid, sid}` —
and = roles conferred by the actor's groups ∪ `["superadmin"]` iff `Swarm.Elevation.active?(uuid, sid)`;
`caps_for/1` derives from that at **every call** — nothing caches an elevated capability, so
expiry/revocation takes effect on the next call with no session state to invalidate.
`Swarm.Actor.resolve/2` passes `{uuid, sid}` from the assertion; `Swarm.Admin` and
`Conversations.admin_read/3` take the same actor ref (the gRPC server passes `{a.uuid, a.sid}`).

**Elevation lifecycle** (`Swarm.Elevation`):

1. `request(actor_id, reason, reauth_token, opts)` — actor must be an active member of `wheel`
   AND `Identity.local_only?/1` (no external IdP link, ADR-19 D8 carried over); `reason` must be
   non-blank; `reauth_token` must verify (below). Any failure ⇒ `{:error, reason}`, audited as a
   denial (`elevate`/`denied`), no row written.
2. The **re-authentication proof** is a channel-signed HS256 token, same shared secret as the
   actor assertion, **distinct audience** `swarm.reauth.v1`, payload
   `{sub, provider: "local", sid, jti, auth_time, iat, exp}`; `exp - iat ≤ 60 s`. The kernel checks:
   signature + audience (`Swarm.Actor.verify/2` with `audience:`), `provider == "local"`,
   `(provider, sub)` resolves to the SAME user as the actor assertion, `sid` equals the actor
   assertion's `sid`, `now - auth_time ≤ reauth_max_age_s` (default 120 s), and the `jti` has
   never been consumed (`elevation.reauth_jti UNIQUE` — a replayed proof cannot re-elevate,
   council: gemini). The channel mints it only after re-verifying the local password
   (`localusers.verify`) in the elevation form — the proof is the cryptographic record that a
   fresh password check happened for THIS subject in THIS session.
3. In ONE transaction: write the `admin_action_audit` row (`elevate` / `allowed` / reason /
   detail `{expires_at, sid}`) FIRST, then insert the `elevation` row with
   `expires_at = now() + ttl` (`ttl` clamped to `[60 s, max_ttl_s]`, default 15 min, max 60 min).
   The audit row is durable at the same instant the capability takes effect (never after).
4. `end/2` (revoke): the holder, or any elevated Wheel member, sets `revoked_at`; audited.
   `active/2` returns the live row for `(user_id, sid)` — `revoked_at IS NULL AND expires_at >
   now()` AND, re-checked at every resolution (council: codex), the user is still `active`, still
   a `wheel` member and still local-only; otherwise the elevation is dead even before expiry.
   Deactivate / delete / remove-from-wheel additionally revoke the user's live elevations in the
   same transaction (belt and suspenders).
5. Scope: per **session** — an elevation is bound to the `sid` of the assertion that requested it;
   another session of the same user is NOT elevated (sudo is per shell, council: codex).
6. Elevation confers NO data visibility (roles ≠ scopes, ADR-20 D8) and no ambient read path:
   `AdminReadConversation` still requires target + reason + per-operation audit (D10).

**Bootstrap invariant:** at least one ACTIVE, local-only member of `wheel` must exist at all
times. The migration asserts it; `Admin` refuses the op that would remove/deactivate/delete the
LAST such member (`{:error, :last_wheel_member}`); `seed_superadmin/1` becomes `seed_wheel/1`
(local user + `wheel` + `admins` membership, no role grant).

## 6. Admin capability boundary (ADR-20 D11)

| Operation | Required | Notes |
| --- | --- | --- |
| list users / groups / roles / projects / sso map (reads) | any admin cap | success not audited, denial audited (unchanged) |
| invite (incl. `external` guest) | `invite_users` | a guest joins no cohort |
| deactivate / delete a user | `manage_users` | ANY mutation targeting a **Wheel member** (today deactivate/delete; any future update/reset): `manage_wheel` (elevation) + never the last member (council: gemini) |
| add/remove a user to `admins` / `staff` | `manage_access` | minting admins stays an admin power (ADR-19 accepted; SSO-mappable); changing ONE'S OWN fixed-group membership needs an elevation (the leave-staff/share/rejoin self-grant, council) |
| add/remove a user to `wheel` | `manage_wheel` (elevation) | local-only members; never the last member |
| project create / rename / describe / delete (confirm) | `manage_projects` **or the Project owner** | creator becomes the Project **owner** member (a direct user membership with role `owner` — groups are never owners); delete cascades memberships + sources (rows become unreachable, not deleted); creating AS `public` needs `manage_publicness` |
| add / remove a Source | `manage_projects` **or the owner** | minting a source = minting its `src:<uuid>`; on a **public** Project add AND remove are `manage_publicness` (a Source added to a public Project is published, one removed un-publishes — council: codex) |
| add / remove a Project member (user or one of the fixed groups) | `manage_access` **or the owner** | `wheel`/`admins`/`staff` may all be members (data access ≠ capability); only the fixed groups. **Self-grant guard**: a member that IS the actor, a group the actor belongs to, or the default cohort (`staff` — every internal account is in it), may be added only by the Project **owner** or under elevation (council: codex — an admin must not mint their own visibility) |
| set project visibility **to or from `public`** | `manage_publicness` (elevation) | `personal` ⇄ `shared` is `manage_projects` |
| group `admin` role bind / clear | `manage_roles` (elevation) | `superadmin` is never bindable → BAD_REQUEST |
| SSO map put / delete | `manage_auth` (elevation) | `wheel` is never an SSO target → BAD_REQUEST (unchanged) |
| group create / delete / rename | rejected (fixed set) | BAD_REQUEST `fixed_group_set`, audited |
| group set scopes / per-user role grant | rejected | BAD_REQUEST, audited (ADR-20 D3 / ADR-19 D2) |
| break-glass conversation read | `read_any_conversation` (elevation) | per-op audit before return (unchanged) |

**Owner delegation.** The Project owner is the data owner: they manage their own Project's
metadata, Sources and members — including sharing it with cohorts they belong to — without an
admin capability. They cannot touch publicness (elevation) and cannot become owners of Projects
they did not create unless an admin/owner adds them as `owner`.

Self-escalation is closed structurally: an admin cannot reach `wheel`, roles, auth config or
publicness without an active elevation, cannot change their own fixed-group membership, cannot
share a Project with themselves or their cohorts unless they own it, and only local Wheel members
can elevate.

## 7. RPC deltas (`proto/core.proto`)

- New: `Elevate(assertion, reason, reauth, ttl_s) → {status, elevation_id, expires_at}`;
  `EndElevation(assertion, elevation_id) → AdminActionResponse`;
  `ListProjects(assertion, mine_only) → [ProjectView]` (an admin cap sees all; any other
  actor sees the Projects they are a member of plus the `public` ones); `GetProject(assertion,
  project_id)` (admin cap or member: full view; a `public` Project: metadata + Sources but NO
  member roster for a non-member; otherwise `NOT_FOUND` — no existence oracle);
  `ManageProject(assertion, op, …)` with `PROJECT_CREATE | RENAME | DELETE | SET_VISIBILITY |
  ADD_SOURCE | REMOVE_SOURCE | ADD_MEMBER | REMOVE_MEMBER`.
- `ResolveActorResponse.elevation_expires_at` (ISO-8601, "" when not elevated) so the channel
  can render the elevation state; `caps` already reflect it.
- `UserView.external`, `ManageUserRequest.external` (guest invite).
- `GroupView.granted_scopes` removed (field number reserved); `AccessOp.SET_GROUP_SCOPES` and
  `GroupOp.GROUP_SET_SCOPES` reserved — the ops answer `BAD_REQUEST`.
- `ManageAccess GRANT_ROLE/REVOKE_ROLE` stay rejected (ADR-19); `GRANT_GROUP/REVOKE_GROUP` keep
  working for the fixed groups under the boundary in §6.

## 8. Channel (hive/web_channel) contract

- `Principal.scopes := ResolveActorResponse.scopes` (kernel-derived); `GROUP_SCOPE_MAP`,
  `KNOWN_SOURCE_SCOPES`, `SWARM_AUTH_BASELINE_GROUP` are removed from env/compose/code; the
  per-credential `scopes` column in the local credential store is vestigial (never authority).
- Admin console gate = ANY admin cap (`is_admin`); elevation-only sections and buttons render
  only when `is_elevated` (kernel caps), with the expiry visible; `/admin/elevate` asks for the
  reason + the local password, re-verifies it, signs the re-auth proof, calls `Elevate`, then
  re-resolves the actor (fresh caps). `/admin/elevation/end` revokes.
- Projects are the user-facing sharing object: `/admin/projects` (+ detail: sources, members,
  visibility), Groups show the fixed three (members only), Users get the `external` (guest)
  flag and their Projects. Source `kind`/`label` are labels; the scope is displayed as the
  opaque `src:<uuid>` it is.

## 9. Owner axis and guests (what this epic does NOT change)

Conversations keep the owner choke-point + RLS (ADR-16 B1). Graph rows carry no owner column
today; a guest's **personal connector** (rows with `owner = guest`) is the deferred E4 epic — this
spec adds NO owner column anywhere (a `source.owner_id` the read gate cannot enforce would be a
false coordinate — council: codex); E4 adds the graph owner axis and the source column together. A guest (`external = true`) therefore sees: `public`, public Projects,
Projects they were explicitly added to, and their own conversations — nothing internal.

## 10. Migration (`20260827090000_project_access`, one transaction, idempotent, census printed)

1. Create the tables of §2; add `app_user.external`.
2. **Census FIRST, while the old tables are intact** (council: gemini — deleting the old groups
   first would cascade their `group_scope_map` rows away and send every baseline scope to
   `Unassigned`): record, per non-deleted user, the OLD effective scope set (old formula:
   `public` ∪ baseline group scopes ∪ own groups' scopes, minus `private`); record every distinct
   scope value over `node`, `edge`, `group_scope_map` (the `src:<name>` labels AND the
   transitional `group`); record each scope's **grant signature** = the set of groups whose
   `group_scope_map` row grants it, with `superuser → admins`, `everyone → staff` applied.
3. Fixed groups: upsert `wheel` / `admins` / `staff`. Move every `superuser` member into
   `wheel` AND `admins` (they keep daily admin without elevating); move every `everyone` member
   into `staff`; add EVERY non-deleted user to `staff` — the default internal cohort. This is the
   exact equivalent of today's authenticated baseline (every actor already gets `everyone`'s
   scopes without membership) and there is no external account on this instance yet
   (`external` is born `false`); the census prints the users it adds (council: codex asked for a
   positive criterion — the positive fact is "no guest exists before this migration").
   Re-point `sso_group_map` rows `everyone → staff`, `admins → admins`, drop any row targeting
   `superuser` (Wheel is never SSO-mappable; logged); delete the `superuser` and `everyone` groups
   (FK cascade); delete `group_role` rows with `superadmin`; ensure `admins → admin`; tighten the
   `group_role` CHECK. "Every user" here means every RESOLVABLE account (`active` or `invited`);
   a `disabled` account holds no membership by design and stays outside the equivalence.
4. Projects from the census — deterministic, deployment-agnostic, NO special cases:
   - scopes sharing a grant signature share one Project; `group` is just another scope name here
     (it lands with whoever granted it — council: codex; no hard-coded "admins see legacy");
   - names: the signature containing `staff` ⇒ **`Internal`**; a non-empty signature without
     `staff` ⇒ **`Operations`**; an EMPTY signature ⇒ **`Unassigned`** with NO members
     (unreachable, fail-closed, flagged for the operator); a second signature with the same base
     name gets the sorted group list appended (`Internal (admins+staff)`);
   - each old scope value becomes one `source` (`kind` = `label` = the old name, `group` ⇒
     `legacy`; `origin = 'migration'`) in its Project; the Project's members are the groups of
     the signature (`source = 'migration'`).
5. **Fold legacy groups** (the group set is fixed): any non-fixed group left over (an old
   IdP-mapped cohort) has already been made a member of its Projects by the signature step —
   now each of its members receives a DIRECT `migration` membership in those Projects, its SSO
   map rows are dropped (logged — future logins mapped to it must be expressed as Project
   membership) and the group row is deleted. Equivalence is asserted after this step, so no
   member loses a scope.
6. Rewrite `node.scope`, `edge.visibility_scope` (`chunk.scope` follows by trigger) from each old
   value to its `src:<uuid>`; drop `group_scope_map` and `role_grant`.
7. Tighten the node/edge CHECK to `private | public | src:<uuid>`; stamp `graph_schema_meta` 11.
8. **Assertions (abort ⇒ rollback, nothing half-applied):**
   - lockout: if any user held group-derived `superadmin` before, then
     `count(active local-only wheel members) ≥ 1` after;
   - **exact equivalence** (no regression AND no widening — council: codex): for EVERY
     non-deleted user, the pre-migration effective scope set (old names mapped to the new uuids)
     EQUALS the post-migration set;
   - completeness: no row left at `group` or at a `src:<name>` that is not a uuid.
9. `down` (structural inverse, `down` never widens): refuses if any `source` with
   `origin = 'admin'` exists (post-migration data has no old-model representation — council:
   gemini/codex) unless `SWARM_MIGRATION_FORCE_DOWN=1`, in which case those rows are clamped to
   `private` (fail-closed, logged); rewrites migration-created `src:<uuid>` back to
   `src:<label>` (`legacy` ⇒ `group`); rebuilds `group_scope_map` from group memberships of the
   reconstructed Projects (user memberships cannot be represented in the old model — logged);
   recreates `role_grant` (empty); restores the wide CHECKs and the old `group_role` CHECK; drops
   the new tables and `app_user.external`; stamps 10. The pre-migration SNAPSHOT stays the
   authoritative full restore, as for ADR-18/19.

Staging cutover recipe (operator): snapshot → build → `migrate` service → kernel + channel up →
real `Core.ask` no-leak matrix (Staff member sees Internal, guest sees only public, Admins see
Operations) → elevation round-trip → verify `groot` ∈ wheel ∧ admins.

## 11. Test plan (the no-leak-class gate)

- **Migration** (round-trip on a seeded old-shape graph): Internal/Operations/Unassigned
  reconstruction, `group` re-homing, uuid rewrite on node/edge/chunk, staff default cohort,
  wheel/admins carry-over, sso map re-pointing, both assertions abort on a seeded lockout /
  regression case, `down` restores the structure.
- **Effective scopes**: user member; group member; non-member ⇒ `["public"]`; guest ⇒
  `["public"]`; Staff via Internal; Admins ⇒ no visibility from the role alone; Wheel ⇒ none
  from the group alone; elevation ⇒ scopes unchanged; public Project ⇒ every authenticated
  actor; flipping it back ⇒ gone; two same-kind sources in two Projects ⇒ distinct scopes and
  no cross-visibility (the `src:<name>` collision regression).
- **Read surfaces** under project-derived scopes: search, traverse/neighborhood, activity,
  aggregation, world-map serve, KbSearch RPC — positive controls (granted ⇒ hits, ungranted ⇒
  0), on the real serve path.
- **Owner axis**: project co-members cannot read each other's conversations; elevation grants
  no conversation read without the per-op break-glass; break-glass still audits before return.
- **Admin boundary**: admin cannot touch `wheel`, roles, sso map, publicness, cannot elevate,
  cannot deactivate a Wheel member; elevated Wheel member can; last-Wheel-member guard.
- **Elevation**: happy path (audit row precedes the elevation row; caps appear); expiry ⇒ caps
  vanish; revoke; stale re-auth (`auth_time` too old) rejected; wrong audience / wrong subject /
  non-local provider rejected; non-Wheel rejected; blank reason rejected; every denial audited.
- **Ingest**: an unregistered `src:*` scope is quarantined; registered passes; `group` is
  rejected by the Contract.

## 12. Deferred (carded)

Connector service identity — binding an ingest write to the Source assigned to the connector's
credential (`connector-service-identity`; council codex+gemini, the accepted limitation of §3);
graph owner axis + personal connectors (`kernel-admin-e4-knowledge-and-connectors`); source
configuration/health in the registry; Project-level ACL / union visibility (ADR-20's stated
forcing condition, not present); revoking elevation on channel-side password change (the channel
does not notify the kernel of credential changes yet).

## 13. Council (design review, 2026-08-27)

Two decorrelated critics on the first draft, both **FLAWED** — folded in as follows:

- **codex (gpt-5.5):** admin self-grant of Project membership → owner-or-elevation self-grant
  guard (§6); Source added to a public Project = publishing → `manage_publicness` (§6); per-user
  elevation → per-`sid` (§5); stale elevation after deactivate/wheel removal → live re-check +
  transactional revoke (§5); legacy `group` hard-coded to Operations → grant-signature rule (§10);
  subset-only assertion → exact equivalence (§10); `source.owner_id` false coordinate → no column
  (§2/§9); enrichers choosing a scope by kind → inherit the anchor (§3); `down` after new data →
  refuse-or-clamp (§10). Accepted as-is: all existing users → `staff` (no guest exists; exact
  baseline equivalence, printed). Documented limitation: connector→Source credential binding.
- **gemini (3.1-pro):** census-before-delete ordering (§10 — the draft would have sent every
  baseline scope to `Unassigned`); re-auth replay → one-time `jti` (§5); anonymous `$1 = NULL`
  → `IS NOT NULL` guard (§4); any mutation of a Wheel member → `manage_wheel` (§6); `down`
  leaving new rows unreadable → rewrite-back (§10). Documented limitation: connector binding.

**Implementation review (review-step, same day — codex ×2, gemini, a Claude tests/docs lens):**
all four returned findings on the first kernel slice; folded: `remove_source` on a public Project
is a publicness act; changing one's OWN fixed-group membership needs an elevation and the default
cohort counts as "self" (the leave-staff/share/rejoin three-step); `GetProject` never returns a
public Project's roster to a non-member; only the fixed groups can be Project members and legacy
groups are folded into direct memberships by the migration; group memberships cannot be owners;
role probes reach `Admin` so they are audited; the raced-jti replay is audited; `delete_user` +
`Person.anonymize` are one transaction; the public-Project derivation requires a live user row.
Refuted with evidence: "chunk mirror left stale" (trigger-maintained, asserted by the migration
test) and "relation edges can carry an unregistered scope" (edge scope = GLB of validated entity
scopes). Test gaps the lens found (ingest quarantine, equivalence abort, co-member conversation
isolation, elevation-without-break-glass, scopes-unchanged-under-elevation, derived-scope read
surfaces) were filled in the same slice.
