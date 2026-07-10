defmodule Swarm.Repo.Migrations.SuperadminViaGroup do
  @moduledoc """
  ADR-19: authority becomes GROUP-derived. Retire the direct-`role_grant` path atomically.

  In one transaction (Ecto wraps each migration): ensure the canonical Superuser/Admins
  groups + their role bindings, migrate every existing DIRECT grant onto the matching
  group, ASSERT a group-derived superadmin survives (abort → rollback if it would lock
  out), then delete all direct grants. Reversal is via DB snapshot (the cutover recipe),
  not a data down-migration.
  """
  use Ecto.Migration

  def up do
    r = repo()

    r.query!(
      "INSERT INTO access_group (id, source, name) VALUES ('superuser','local','Superuser') ON CONFLICT (id) DO NOTHING"
    )

    r.query!(
      "INSERT INTO access_group (id, source, name) VALUES ('admins','local','Admins') ON CONFLICT (id) DO NOTHING"
    )

    r.query!(
      "INSERT INTO group_role (group_id, role) VALUES ('superuser','superadmin') ON CONFLICT (group_id, role) DO NOTHING"
    )

    r.query!(
      "INSERT INTO group_role (group_id, role) VALUES ('admins','admin') ON CONFLICT (group_id, role) DO NOTHING"
    )

    [[had_direct_superadmin]] =
      r.query!("SELECT count(*)::int FROM role_grant WHERE role = 'superadmin'").rows

    # move direct holders onto the matching group so their authority survives the switch
    r.query!("""
    INSERT INTO user_group (user_id, group_id, source)
    SELECT DISTINCT user_id, 'superuser', 'local' FROM role_grant WHERE role = 'superadmin'
    ON CONFLICT (user_id, group_id) DO NOTHING
    """)

    r.query!("""
    INSERT INTO user_group (user_id, group_id, source)
    SELECT DISTINCT user_id, 'admins', 'local' FROM role_grant WHERE role = 'admin'
    ON CONFLICT (user_id, group_id) DO NOTHING
    """)

    [[group_superadmins]] =
      r.query!("""
      SELECT count(DISTINCT ug.user_id)::int
        FROM user_group ug
        JOIN group_role gr ON gr.group_id = ug.group_id
       WHERE gr.role = 'superadmin'
      """).rows

    # bootstrap safety (codex): only abort if we HAD a direct superadmin and failed to
    # carry it over — a fresh/empty DB (had_direct_superadmin = 0) has nothing to lose.
    if had_direct_superadmin > 0 and group_superadmins < 1 do
      raise "ADR-19 migration abort: no group-derived superadmin after migration (would lock out)"
    end

    # retire the direct authority path entirely
    r.query!("DELETE FROM role_grant")
  end

  def down do
    # The forward step is a one-way authority-source switch; roll back via the DB
    # snapshot taken in the deploy cutover, not a reconstructed data down-migration.
    :ok
  end
end
