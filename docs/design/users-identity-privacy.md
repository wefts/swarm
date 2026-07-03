---
status: draft
adr: workspace ADR-16 (Accepted 2026-07-01)
owns: swarm kernel — identity/ownership/enforcement; hive channel contract described
supersedes: nothing (elaborates ADR-7 opaque-viewer; data-foundation P5)
---

# Users — identity, access, per-user privacy (design spec)

Implements workspace **ADR-16**. Field-level sketch: `board/ideas/users-identity-schema.yaml`.
MVP for a self-hosted, non-public, single-box instance going from 2 people to a small
invited cohort. Personal work assistant, not ChatGPT.

## Ownership split (ADR-16 A/B)

- **Kernel (`swarm/`)** owns the **authorization** record + **conversation ownership** +
  **all visibility enforcement**. It is the sole authority.
- **Channel (`hive/web_channel`)** owns **authentication only** — password (pbkdf2), OIDC
  flow, sessions/cookies, the admin UI — and forwards a **signed actor assertion** to the
  kernel (Decision 9). It never reads the kernel DB (hive ADR-1).

## Verified actor assertion (ADR-16 Decision 9 — the crux)

The kernel does **not** trust a plaintext `{viewer, scopes}`. Each request carries a
**signed** assertion the kernel verifies (single box: HMAC/JWT with a shared secret in
`hive/secrets.env`; mTLS later). Payload: `{ sub, provider, session_id, issued_at, exp }`.
The kernel then **derives** `{uuid, scopes, caps}` itself from its own records (role_grant,
group_scope_map) — the channel supplies *who authenticated*, the kernel decides *what they
may do*. This revisits ADR-7 for security-bearing paths (conversation reads, grants).
Scope derivation carries the **authenticated baseline `public`** (any active, resolved actor reads public knowledge — mirrors the channel boundary and the anonymous/legacy `norm_scopes` default); default-deny applies to everything above it (groups → group_scope_map; `private` ungrantable). Added 2026-07-03 after the staging KB-dead regression (an unseeded group_scope_map made every signed actor derive `[]`).

## Data model (kernel-owned unless noted)

> Physical table names dodge the Postgres reserved words `user`/`group` (also the
> `USER`/`CURRENT_USER`/`GROUP` keywords — a bare `user` in raw SQL silently means
> the DB role, a security-adjacent footgun here since the kernel writes raw SQL):
> **`user` → `app_user`**, **`group` → `access_group`**. The join/map/grant names
> are as written. Ids on `app_user`/`role_grant` are app-minted **UUIDv7** (RFC 9562,
> ms-granular time ordering → index locality); child-row ids default to core
> `gen_random_uuid()`. Tables are auxiliary (like `deliberation`) — no graph-schema
> bump. (Step 1 landed: `Swarm.Identity` + migration `20260701140000_identity_store`.)

- **user**(id `UUIDv7` PK, login unique [=IdP uid], first_name?, last_name?, nickname?,
  status `active|invited|disabled|deleted`, created_at, updated_at, last_login_at). No
  creds, no email column.
- **user_email**(id, user_id→user, email unique, verified_at?, is_primary).
- **credential** [CHANNEL, secret] — pbkdf2 (salt/hash/iterations). Never in kernel/graph/commits.
- **identity_link**(id, user_id→user, provider, subject [stable IdP `sub`], verified_at,
  unique(provider, subject)) — SSO JIT find-or-create; account-linking → one uuid.
- **group**(id, source `idp|local`) · **user_group**(user_id, group_id, source, created_at)
  · **group_scope_map**(group_id, scopes[]) — kernel-owned, admin-mutable (Decision 10),
  config may seed. Default-deny.
- **role_grant**(user_id, role `admin|superadmin`, source `direct|group|sso_group`,
  granted_by, granted_at) — source-agnostic; default-deny. Capabilities: admin =
  {manage_access, invite_users, manage_users}; superadmin = all + read_any_conversation.
- **conversation**(id `UUIDv7`, owner_id→user **NOT NULL**, scope?, title, created_at,
  updated_at, deleted_at?) · **message**(id, conversation_id→conversation, author_user_id→user,
  role `user|assistant`, body, ask_ref?, created_at). Owner ≠ author in general.
- **admin_action_audit**(id, actor_id, action `read_conversation|grant|revoke|invite|deactivate|delete`,
  target_user_id?, target_ids/scope?, reason, request_id, decision, data_returned bool, at)
  — append-only; **written before** any break-glass data is returned.
- **person_node** [GRAPH] — projected on the same uuid (type `person`); bio? + facts as
  claim-edges (based_in/interested_in/works_on/role/member_of). Never creds/sub.

Superadmin = a local account whose id is a normal `UUIDv7` but a recognizable/vanity value,
seeded at bootstrap (root/uid-0 feel).

## Visibility enforcement (the invariant)

Two axes, one predicate applied to **every** read:
`visible ⇔ (scope IS NULL OR scope ∈ viewer.scopes) AND (owner IS NULL OR owner = viewer.id OR viewer.admin_audited_read)`.

- **One data-access choke point** per owned entity injects `owner = <verified subject>`
  (never caller-supplied). Reuse the proven `Swarm.Deliberation` owner + scope-re-auth
  pattern (aux table, opaque handle).
- **Postgres RLS** as the belt-and-suspenders net (per-txn `SET LOCAL app.current_user`),
  so a future new path / export / search cannot escape the DB policy.
- Deny-by-default; UUID ids; **404-not-403** (no existence oracle).
- **Every path** obeys it: list, get, search, cursor, neighborhood, activity, export,
  errors. Adversarial-tested (below).

## RPCs (Core API additions, sketch)

- `ResolveActor(assertion) → {uuid, scopes, caps}` (or inline in each RPC's auth seam).
- `LogConversation` / `ListConversations(viewer)` / `GetConversation(viewer, id)` — owner-gated.
- `AdminReadConversation(actor, target, reason)` — break-glass: **impersonate the target's
  view via the SAME predicate**, audit-before-return; superadmin + `read_any_conversation` only.
- `ManageAccess(actor, grant|revoke, target, group|scope)` / `InviteUser` / `DeactivateUser`
  / `DeleteUser` — gated by caps; audited. **admin cannot touch another user's own KB.**

## Account lifecycle (Decision 11)

Deactivate/delete → **credential + sessions + role_grant + access die immediately** (login
dead). **Learned/derived content persists** (graph facts, person-node knowledge, shared-
resource contributions) — decoupled from the auth record; scope-governed; *not* a
right-to-erasure (self-hosted, learning is the plan). Orphaned person-node → anonymize/detach,
never dangle. Raw-private-conversation purge-vs-keep = the deferred retention policy.

## Service / agent identity (council gap)

Background jobs, the enrichment loop, indexers, backups, MCP/tool calls act under a
**service identity** and are authorized too — critically, **enrichment must respect
conversation ownership** (never surface one user's chat-derived facts to another via the graph).

## Migration without lockout

Existing channel local users + `groot` + SSO test users → upsert into kernel `user` +
`role_grant` (groot → superadmin, vanity uuid) before cutover; verify everyone can still log
in; keep the channel store readable until verified.

## Adversarial test plan (the no-leak-class gate)

Per owned-entity RPC + every read path: **user A cannot read user B** (list/get/search/
cursor/neighborhood/activity/export/error); **404 not 403**; admin break-glass writes audit
**before** returning + is impersonation-not-bypass; **RLS holds under connection-pool reuse**;
**enrichment/service identity respects owner**; person-node facts don't leak into scoped
corpus reads. Same rigor as the scope no-leak suite.

## Channel responsibilities (hive)

authN (pbkdf2 + OIDC) · session · **sign the actor assertion** · admin UI (invite/deactivate/
delete, manage_access, break-glass read) · seed group→role/scope config. No DB reads; no
scope/authz decisions (kernel derives those).
