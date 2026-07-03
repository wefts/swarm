defmodule Swarm.Repo.Migrations.RlsAppRole do
  use Ecto.Migration

  # board/todo/rls-app-role (ADR-16 step-3 gate) — the non-superuser runtime role
  # that makes the Postgres RLS belt LIVE. Council 2026-07-03 (codex + gemini,
  # both SOUND-WITH-CAVEATS, convergent):
  #
  #   * the role is created NOLOGIN and NO password ever enters migration code —
  #     enabling login is a deliberate OPERATOR action
  #     (`ALTER ROLE swarm_app LOGIN PASSWORD '…'` by hand; Ecto logs execute/1
  #     SQL, so a password here would leak into deploy logs — gemini);
  #   * grants are DML + sequences only — NO `EXECUTE ON ALL FUNCTIONS` (would
  #     silently expose future SECURITY DEFINER helpers — codex), NO TRUNCATE
  #     anywhere; extension/built-in functions are PUBLIC-executable by default;
  #   * default privileges are pinned EXPLICITLY to the role running migrations
  #     (tables created by future migrations stay readable — gemini);
  #   * audit tamper-resistance: UPDATE/DELETE/TRUNCATE revoked on
  #     admin_action_audit (INSERT + SELECT stay — append-only at the DB);
  #   * the break-glass owner lookup becomes a hardened SECURITY DEFINER fn
  #     (STABLE, search_path pinned with pg_temp LAST, schema-qualified,
  #     EXECUTE only for swarm_app) — under RLS a raw owner-unfiltered SELECT
  #     would silently return nothing and kill break-glass.
  #
  # The kernel keeps connecting as the privileged role until the operator flips
  # SWARM_KERNEL_DB_USER/-PASSWORD (hive compose) — this migration alone is a
  # safe no-op for the running system. `down` drops only the function: the role
  # is cluster-wide (shared across DBs on the instance), not this DB's to drop.

  def up do
    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'swarm_app') THEN
        CREATE ROLE swarm_app NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOLOGIN;
      END IF;
    END $$
    """)

    execute("GRANT USAGE ON SCHEMA public TO swarm_app")
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO swarm_app")
    execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO swarm_app")

    # Future tables/sequences created by the migration role (pinned explicitly —
    # current_user is the role that runs migrations in every environment).
    execute("""
    DO $$ BEGIN
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public
           GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO swarm_app',
        current_user
      );
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public
           GRANT USAGE, SELECT ON SEQUENCES TO swarm_app',
        current_user
      );
    END $$
    """)

    execute("REVOKE UPDATE, DELETE, TRUNCATE ON admin_action_audit FROM swarm_app")

    execute("""
    CREATE OR REPLACE FUNCTION public.conversation_owner_lookup(cid uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, public, pg_temp
    AS $fn$
      SELECT c.owner_id
        FROM public.conversation AS c
       WHERE c.id = cid
         AND c.deleted_at IS NULL
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION public.conversation_owner_lookup(uuid) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION public.conversation_owner_lookup(uuid) TO swarm_app")
  end

  def down do
    execute("DROP FUNCTION IF EXISTS public.conversation_owner_lookup(uuid)")
  end
end
