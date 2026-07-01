defmodule Swarm.Repo.Migrations.ConversationStore do
  use Ecto.Migration

  # Workspace ADR-16 step 3 — conversations as a kernel-owned aux entity, private
  # per owner (the NEW no-leak-class invariant). Enforced two ways, belt-and-braces:
  #
  #   1. PRIMARY — one data-access choke point (`Swarm.Conversations`) that injects
  #      `owner_id = <verified subject>` (from `Swarm.Actor.resolve`, never caller-
  #      supplied) into every read/write. This is the guarantee that holds today.
  #   2. BELT — Postgres RLS (FORCE) so a *future* new path / export / search cannot
  #      escape the owner predicate at the DB. NB RLS is bypassed by a superuser /
  #      BYPASSRLS / owning role — the deployed `swarm` role is currently superuser,
  #      so the belt is DORMANT until the kernel connects as a non-superuser app role
  #      (`board/todo/rls-app-role`, a deployment hardening). The policy is proven to
  #      bite under a non-superuser role in the test suite regardless.
  #
  # Aux tables (no graph-schema bump; no node FK). owner ≠ author in general
  # (`message.author_user_id`). Account deletion / conversation retention is the
  # DEFERRED policy (ADR-16 D11) — so no ON DELETE CASCADE from app_user here; a
  # user with conversations cannot be hard-deleted until step 5 decides purge-vs-keep.

  def up do
    create table(:conversation, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:owner_id, references(:app_user, type: :uuid, on_delete: :restrict), null: false)
      # Usually NULL (owner-private); set only if a conversation is deliberately shared.
      add(:scope, :text)
      add(:title, :text)
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
      add(:updated_at, :timestamptz, null: false, default: fragment("now()"))
      add(:deleted_at, :timestamptz)
    end

    create(index(:conversation, [:owner_id]))

    create table(:message, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:conversation_id, references(:conversation, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:author_user_id, references(:app_user, type: :uuid, on_delete: :nilify_all))
      add(:role, :text, null: false)
      add(:body, :text, null: false)
      add(:ask_ref, :text)
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(constraint(:message, :message_role_vocab, check: "role IN ('user','assistant')"))
    create(index(:message, [:conversation_id]))

    # ── RLS belt (dormant under a superuser/BYPASSRLS connection; see header) ──
    # The choke point sets `app.current_user` (a transaction-local GUC) to the
    # verified owner uuid; the policy admits only that owner's rows. `current_setting
    # (..., true)` returns NULL when unset ⇒ no rows ⇒ fail closed (never all-rows).
    execute(
      "ALTER TABLE conversation ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE conversation DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE conversation FORCE ROW LEVEL SECURITY",
      "ALTER TABLE conversation NO FORCE ROW LEVEL SECURITY"
    )

    # NULLIF(..., '') so an empty GUC (after reset / session reuse) casts to NULL →
    # zero rows (fail closed), never a cast-error 500 (council: codex).
    execute(
      """
      CREATE POLICY conversation_owner ON conversation
        USING (owner_id = NULLIF(current_setting('app.current_user', true), '')::uuid)
      """,
      "DROP POLICY IF EXISTS conversation_owner ON conversation"
    )

    execute(
      "ALTER TABLE message ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE message DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE message FORCE ROW LEVEL SECURITY",
      "ALTER TABLE message NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY message_owner ON message
        USING (EXISTS (
          SELECT 1 FROM conversation c
           WHERE c.id = message.conversation_id
             AND c.owner_id = NULLIF(current_setting('app.current_user', true), '')::uuid
        ))
      """,
      "DROP POLICY IF EXISTS message_owner ON message"
    )
  end

  def down do
    drop(table(:message))
    drop(table(:conversation))
  end
end
