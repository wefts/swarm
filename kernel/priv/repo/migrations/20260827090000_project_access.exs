defmodule Swarm.Repo.Migrations.ProjectAccess do
  @moduledoc """
  Workspace ADR-20 — Projects are the sole data-access container; `src:<source_uuid>` is the
  stable source scope; fixed groups `wheel` / `admins` / `staff`; superadmin only as an
  elevation. Design: `docs/design/project-access.md` §10. One transaction (Ecto wraps the
  migration), idempotent (a second run on a migrated DB only re-asserts the schema), census
  printed, and it ABORTS (⇒ rollback, nothing half-applied) on a lockout or on any change of
  any user's effective visibility.

  Order matters (council gemini): the CENSUS of the old model runs FIRST, while
  `group_scope_map` and the old groups are intact — deleting the groups first would cascade
  their grant rows away and send every baseline scope to `Unassigned`.

  `apply_up!/1` / `apply_down!/1` take the repo so the round-trip test can drive them directly.
  """
  use Ecto.Migration

  @uuid_re "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @src_uuid_check "^src:" <> @uuid_re <> "$"
  @old_scope_check "IN ('private','public','group') OR %s ~ '^src:[a-z0-9_-]+$'"
  @fixed_groups [{"wheel", "Wheel"}, {"admins", "Admins"}, {"staff", "Staff"}]

  def up, do: apply_up!(repo())
  def down, do: apply_down!(repo())

  # ── up ───────────────────────────────────────────────────────────────────

  def apply_up!(repo) do
    ensure_schema!(repo)

    if migrated?(repo) do
      IO.puts("project_access: already migrated — schema re-asserted, no data step")
      :ok
    else
      census = census!(repo)
      move_groups!(repo, census)
      mapping = build_projects!(repo, census)
      rewrite_scopes!(repo, mapping)
      drop_old_tables!(repo)
      tighten_checks!(repo)
      assert_lockout!(repo, census)
      assert_equivalence!(repo, census, mapping)
      assert_complete!(repo)
      repo.query!("UPDATE graph_schema_meta SET version = 11 WHERE id = 1")
      IO.puts("project_access: graph_schema_meta version=11")
      :ok
    end
  end

  # The old grant table is the marker: once it is gone, the data steps have run.
  defp migrated?(repo), do: is_nil(regclass(repo, "public.group_scope_map"))

  defp regclass(repo, name) do
    %{rows: [[oid]]} = repo.query!("SELECT to_regclass($1)", [name])
    oid
  end

  # Idempotent DDL (IF NOT EXISTS everywhere) — safe to re-run.
  defp ensure_schema!(repo) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS project (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      description text,
      visibility text NOT NULL DEFAULT 'shared'
        CONSTRAINT project_visibility_vocab CHECK (visibility IN ('personal','shared','public')),
      created_by uuid,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    repo.query!("""
    CREATE TABLE IF NOT EXISTS source (
      id uuid PRIMARY KEY,
      project_id uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      kind text NOT NULL,
      label text NOT NULL,
      origin text NOT NULL DEFAULT 'admin'
        CONSTRAINT source_origin_vocab CHECK (origin IN ('migration','admin')),
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    repo.query!("CREATE INDEX IF NOT EXISTS source_project_id_idx ON source (project_id)")

    repo.query!("""
    CREATE TABLE IF NOT EXISTS project_membership (
      project_id uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      user_id uuid REFERENCES app_user(id) ON DELETE CASCADE,
      group_id text REFERENCES access_group(id) ON DELETE CASCADE,
      role text NOT NULL DEFAULT 'member'
        CONSTRAINT project_membership_role_vocab CHECK (role IN ('owner','member')),
      source text NOT NULL DEFAULT 'local'
        CONSTRAINT project_membership_source_vocab CHECK (source IN ('local','migration')),
      granted_by uuid,
      created_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT project_membership_one_subject CHECK ((user_id IS NULL) <> (group_id IS NULL))
    )
    """)

    repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS project_membership_user_uq
      ON project_membership (project_id, user_id) WHERE user_id IS NOT NULL
    """)

    repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS project_membership_group_uq
      ON project_membership (project_id, group_id) WHERE group_id IS NOT NULL
    """)

    repo.query!(
      "CREATE INDEX IF NOT EXISTS project_membership_user_idx ON project_membership (user_id)"
    )

    repo.query!(
      "CREATE INDEX IF NOT EXISTS project_membership_group_idx ON project_membership (group_id)"
    )

    repo.query!("""
    CREATE TABLE IF NOT EXISTS elevation (
      id uuid PRIMARY KEY,
      user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
      reason text NOT NULL,
      sid text NOT NULL,
      reauth_jti text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      expires_at timestamptz NOT NULL,
      revoked_at timestamptz
    )
    """)

    repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS elevation_reauth_jti_uq ON elevation (reauth_jti)"
    )

    repo.query!(
      "CREATE INDEX IF NOT EXISTS elevation_user_idx ON elevation (user_id, expires_at)"
    )

    repo.query!(
      "ALTER TABLE app_user ADD COLUMN IF NOT EXISTS external boolean NOT NULL DEFAULT false"
    )

    # The runtime role must be able to use the new tables (RLS belt deployments; the ADR-16
    # rls-app-role default privileges are pinned to the migration role, but be explicit).
    repo.query!("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'swarm_app') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON project, source, project_membership, elevation TO swarm_app;
      END IF;
    END $$
    """)

    :ok
  end

  # ── census (BEFORE any change) ─────────────────────────────────────────────

  defp census!(repo) do
    baseline = System.get_env("SWARM_AUTH_BASELINE_GROUP", "everyone")

    grants =
      repo.query!("SELECT group_id, scopes FROM group_scope_map").rows
      |> Map.new(fn [g, scopes] -> {g, Enum.reject(scopes, &(&1 == "private"))} end)

    memberships =
      repo.query!("SELECT user_id::text, group_id FROM user_group").rows
      |> Enum.group_by(&hd/1, &Enum.at(&1, 1))

    users =
      repo.query!(
        "SELECT id::text, login FROM app_user WHERE status IN ('active','invited') ORDER BY login"
      ).rows

    old_scopes =
      Map.new(users, fn [id, login] ->
        groups = Map.get(memberships, id, [])

        scopes =
          (["public"] ++
             Map.get(grants, baseline, []) ++
             Enum.flat_map(groups, &Map.get(grants, &1, [])))
          |> Enum.uniq()
          |> Enum.sort()

        {id, {login, scopes}}
      end)

    graph_scopes =
      repo.query!("""
      SELECT DISTINCT scope FROM node WHERE scope NOT IN ('private','public')
      UNION
      SELECT DISTINCT visibility_scope FROM edge WHERE visibility_scope NOT IN ('private','public')
      """).rows
      |> List.flatten()

    granted_scopes = grants |> Map.values() |> List.flatten()

    scope_values =
      (graph_scopes ++ granted_scopes)
      |> Enum.reject(&(&1 in ["private", "public"]))
      |> Enum.uniq()
      |> Enum.sort()

    # grant signature: the (renamed) groups whose grant row confers the scope
    signatures =
      Map.new(scope_values, fn scope ->
        sig =
          grants
          |> Enum.filter(fn {_g, scopes} -> scope in scopes end)
          |> Enum.map(fn {g, _} -> rename_group(g, baseline) end)
          |> Enum.uniq()
          |> Enum.sort()

        {scope, sig}
      end)

    [[had_superadmin]] =
      repo.query!("""
      SELECT count(DISTINCT ug.user_id)::int
        FROM user_group ug JOIN group_role gr ON gr.group_id = ug.group_id
       WHERE gr.role = 'superadmin'
      """).rows

    IO.puts(
      "project_access census: users=#{map_size(old_scopes)} scopes=#{inspect(scope_values)} " <>
        "grant_groups=#{inspect(Map.keys(grants))} superadmin_holders=#{had_superadmin}"
    )

    for {scope, sig} <- signatures do
      IO.puts("project_access census: #{scope} <- #{inspect(sig)}")
    end

    %{
      baseline: baseline,
      old_scopes: old_scopes,
      scope_values: scope_values,
      signatures: signatures,
      had_superadmin: had_superadmin > 0
    }
  end

  defp rename_group("superuser", _baseline), do: "admins"
  defp rename_group(g, baseline) when g == baseline, do: "staff"
  defp rename_group("everyone", _baseline), do: "staff"
  defp rename_group(g, _baseline), do: g

  # ── fixed groups ───────────────────────────────────────────────────────────

  defp move_groups!(repo, census) do
    for {id, name} <- @fixed_groups do
      repo.query!(
        """
        INSERT INTO access_group (id, source, name) VALUES ($1, 'local', $2)
        ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name
        """,
        [id, name]
      )
    end

    # superuser → wheel AND admins (daily admin without elevating)
    for target <- ["wheel", "admins"] do
      repo.query!(
        """
        INSERT INTO user_group (user_id, group_id, source)
        SELECT user_id, $1, 'local' FROM user_group WHERE group_id = 'superuser'
        ON CONFLICT (user_id, group_id) DO NOTHING
        """,
        [target]
      )
    end

    # everyone (and the configured baseline group, if different) → staff
    for old <- Enum.uniq(["everyone", census.baseline]) do
      repo.query!(
        """
        INSERT INTO user_group (user_id, group_id, source)
        SELECT user_id, 'staff', source FROM user_group WHERE group_id = $1
        ON CONFLICT (user_id, group_id) DO NOTHING
        """,
        [old]
      )
    end

    # the default internal cohort: every account that can resolve today. There is no
    # external account before this migration (`external` is born false) and every actor
    # already received the baseline without membership — exact equivalence, printed.
    %{num_rows: cohort} =
      repo.query!("""
      INSERT INTO user_group (user_id, group_id, source)
      SELECT id, 'staff', 'default' FROM app_user WHERE status IN ('active','invited')
      ON CONFLICT (user_id, group_id) DO NOTHING
      """)

    IO.puts("project_access: default cohort — #{cohort} user(s) added to staff")

    %{num_rows: sso_dropped} =
      repo.query!("DELETE FROM sso_group_map WHERE our_group_id = 'superuser'")

    if sso_dropped > 0,
      do: IO.puts("project_access: dropped #{sso_dropped} sso map row(s) targeting superuser")

    for old <- Enum.uniq(["everyone", census.baseline]) do
      repo.query!("UPDATE sso_group_map SET our_group_id = 'staff' WHERE our_group_id = $1", [old])
    end

    repo.query!(
      "DELETE FROM access_group WHERE id = ANY($1::text[])",
      [Enum.uniq(["superuser", "everyone", census.baseline]) -- ["staff", "admins", "wheel"]]
    )

    repo.query!("DELETE FROM group_role WHERE role <> 'admin'")

    repo.query!(
      "INSERT INTO group_role (group_id, role) VALUES ('admins','admin') ON CONFLICT (group_id, role) DO NOTHING"
    )

    repo.query!("ALTER TABLE group_role DROP CONSTRAINT IF EXISTS group_role_vocab")

    repo.query!(
      "ALTER TABLE group_role ADD CONSTRAINT group_role_vocab CHECK (role IN ('admin'))"
    )

    :ok
  end

  # ── projects from the grant signatures ─────────────────────────────────────

  defp build_projects!(repo, census) do
    by_sig =
      census.scope_values
      |> Enum.group_by(&Map.fetch!(census.signatures, &1))
      |> Enum.sort_by(fn {sig, _} -> sig end)

    bases = Enum.map(by_sig, fn {sig, _} -> {sig, base_name(sig)} end)

    by_sig
    |> Enum.flat_map(fn {sig, scopes} ->
      base = base_name(sig)
      collides? = Enum.count(bases, fn {_s, b} -> b == base end) > 1
      name = if collides?, do: base <> " (" <> Enum.join(sig, "+") <> ")", else: base

      %{rows: [[pid]]} =
        repo.query!(
          """
          INSERT INTO project (id, name, description, visibility)
          VALUES (gen_random_uuid(), $1, $2, 'shared')
          RETURNING id::text
          """,
          [
            name,
            "Reconstructed by the ADR-20 migration from the ADR-18 group grants " <>
              inspect(sig) <> "."
          ]
        )

      pid_bin = Ecto.UUID.dump!(pid)

      for g <- sig do
        repo.query!(
          """
          INSERT INTO project_membership (project_id, group_id, role, source)
          VALUES ($1, $2, 'member', 'migration')
          """,
          [pid_bin, g]
        )
      end

      IO.puts(
        "project_access: project #{inspect(name)} members=#{inspect(sig)} scopes=#{inspect(scopes)}"
      )

      Enum.map(scopes, fn old ->
        label = old_label(old)

        %{rows: [[sid]]} =
          repo.query!(
            """
            INSERT INTO source (id, project_id, kind, label, origin)
            VALUES (gen_random_uuid(), $1, $2, $2, 'migration')
            RETURNING id::text
            """,
            [pid_bin, label]
          )

        {old, "src:" <> sid}
      end)
    end)
    |> Map.new()
  end

  defp base_name([]), do: "Unassigned"
  defp base_name(sig), do: if("staff" in sig, do: "Internal", else: "Operations")

  defp old_label("group"), do: "legacy"
  defp old_label("src:" <> name), do: name
  defp old_label(other), do: other

  defp rewrite_scopes!(repo, mapping) do
    for {old, new} <- mapping do
      %{num_rows: n} = repo.query!("UPDATE node SET scope = $2 WHERE scope = $1", [old, new])

      %{num_rows: e} =
        repo.query!("UPDATE edge SET visibility_scope = $2 WHERE visibility_scope = $1", [
          old,
          new
        ])

      IO.puts("project_access: #{old} -> #{new} nodes=#{n} edges=#{e}")
    end

    :ok
  end

  defp drop_old_tables!(repo) do
    repo.query!("DROP TABLE IF EXISTS group_scope_map")
    repo.query!("DROP TABLE IF EXISTS role_grant")
    :ok
  end

  defp tighten_checks!(repo) do
    repo.query!("ALTER TABLE node DROP CONSTRAINT IF EXISTS node_scope_vocab")

    repo.query!(
      "ALTER TABLE node ADD CONSTRAINT node_scope_vocab CHECK (scope IN ('private','public') OR scope ~ '#{@src_uuid_check}')"
    )

    repo.query!("ALTER TABLE edge DROP CONSTRAINT IF EXISTS edge_scope_vocab")

    repo.query!(
      "ALTER TABLE edge ADD CONSTRAINT edge_scope_vocab CHECK (visibility_scope IN ('private','public') OR visibility_scope ~ '#{@src_uuid_check}')"
    )

    IO.puts("project_access: node/edge scope CHECK tightened to private|public|src:<uuid>")
    :ok
  end

  # ── assertions (abort ⇒ rollback) ─────────────────────────────────────────

  defp assert_lockout!(repo, %{had_superadmin: true}) do
    [[n]] = repo.query!(wheel_members_sql()).rows

    if n < 1 do
      raise "ADR-20 migration abort: no ACTIVE local-only wheel member after migration (would lock out break-glass)"
    end

    IO.puts("project_access: lockout check ok — #{n} active local-only wheel member(s)")
  end

  defp assert_lockout!(_repo, _census),
    do: IO.puts("project_access: no prior superadmin — lockout check n/a")

  defp wheel_members_sql do
    """
    SELECT count(*)::int
      FROM app_user u
      JOIN user_group ug ON ug.user_id = u.id AND ug.group_id = 'wheel'
     WHERE u.status = 'active'
       AND EXISTS (SELECT 1 FROM identity_link l WHERE l.user_id = u.id AND l.provider = 'local')
       AND NOT EXISTS (SELECT 1 FROM identity_link l WHERE l.user_id = u.id AND l.provider <> 'local')
    """
  end

  # Exact equivalence (council codex): every resolvable user's effective scopes are IDENTICAL
  # before and after — no regression (lockout) and no widening (leak).
  defp assert_equivalence!(repo, census, mapping) do
    Enum.each(census.old_scopes, fn {id, {login, old}} ->
      expected = old |> Enum.map(&Map.get(mapping, &1, &1)) |> Enum.uniq() |> Enum.sort()

      actual =
        (["public"] ++
           (repo.query!(effective_scopes_sql(), [Ecto.UUID.dump!(id)]).rows |> List.flatten()))
        |> Enum.uniq()
        |> Enum.sort()

      if expected != actual do
        raise "ADR-20 migration abort: effective scopes changed for #{login}: " <>
                "before=#{inspect(expected)} after=#{inspect(actual)}"
      end
    end)

    IO.puts(
      "project_access: equivalence check ok — #{map_size(census.old_scopes)} user(s) unchanged"
    )
  end

  defp effective_scopes_sql do
    """
    SELECT DISTINCT 'src:' || s.id::text
      FROM source s
      JOIN project p ON p.id = s.project_id
     WHERE ($1::uuid IS NOT NULL AND p.visibility = 'public')
        OR EXISTS (SELECT 1 FROM project_membership pm
                    WHERE pm.project_id = p.id AND pm.user_id = $1::uuid)
        OR EXISTS (SELECT 1 FROM project_membership pm
                    JOIN user_group ug ON ug.group_id = pm.group_id
                    WHERE pm.project_id = p.id AND ug.user_id = $1::uuid)
    """
  end

  defp assert_complete!(repo) do
    [[left]] =
      repo.query!("""
      SELECT (SELECT count(*) FROM node WHERE scope NOT IN ('private','public') AND scope !~ '#{@src_uuid_check}')
           + (SELECT count(*) FROM edge WHERE visibility_scope NOT IN ('private','public') AND visibility_scope !~ '#{@src_uuid_check}')
      """).rows

    if left > 0, do: raise("ADR-20 migration abort: #{left} row(s) left at a non-uuid scope")
    IO.puts("project_access: completeness ok — every row is private|public|src:<uuid>")
  end

  # ── down (structural inverse; never widens) ───────────────────────────────

  def apply_down!(repo) do
    if not migrated?(repo) or is_nil(regclass(repo, "public.source")) do
      IO.puts("project_access down: old model already in place — nothing to do")
      :ok
    else
      admin_sources =
        repo.query!("SELECT id::text, label FROM source WHERE origin = 'admin'").rows

      if admin_sources != [] and System.get_env("SWARM_MIGRATION_FORCE_DOWN") != "1" do
        raise "ADR-20 down refused: #{length(admin_sources)} post-migration source(s) exist " <>
                "(#{inspect(Enum.map(admin_sources, &Enum.at(&1, 1)))}); restore the pre-migration " <>
                "snapshot, or set SWARM_MIGRATION_FORCE_DOWN=1 to clamp their rows to private"
      end

      restore_old_checks!(repo)

      for [sid, label] <- admin_sources do
        scope = "src:" <> sid
        repo.query!("UPDATE node SET scope = 'private' WHERE scope = $1", [scope])

        repo.query!("UPDATE edge SET visibility_scope = 'private' WHERE visibility_scope = $1", [
          scope
        ])

        IO.puts(
          "project_access down: post-migration source #{label} (#{scope}) clamped to private"
        )
      end

      recreate_old_tables!(repo)
      rebuild_grants!(repo)

      for [sid, label] <-
            repo.query!("SELECT id::text, label FROM source WHERE origin = 'migration'").rows do
        old = if label == "legacy", do: "group", else: "src:" <> label
        scope = "src:" <> sid
        %{num_rows: n} = repo.query!("UPDATE node SET scope = $2 WHERE scope = $1", [scope, old])

        %{num_rows: e} =
          repo.query!("UPDATE edge SET visibility_scope = $2 WHERE visibility_scope = $1", [
            scope,
            old
          ])

        IO.puts("project_access down: #{scope} -> #{old} nodes=#{n} edges=#{e}")
      end

      repo.query!("DROP TABLE IF EXISTS elevation")
      repo.query!("DROP TABLE IF EXISTS project_membership")
      repo.query!("DROP TABLE IF EXISTS source")
      repo.query!("DROP TABLE IF EXISTS project")
      repo.query!("ALTER TABLE app_user DROP COLUMN IF EXISTS external")
      repo.query!("UPDATE graph_schema_meta SET version = 10 WHERE id = 1")

      IO.puts(
        "project_access down: graph_schema_meta version=10 (snapshot is the authoritative full restore)"
      )

      :ok
    end
  end

  defp restore_old_checks!(repo) do
    repo.query!("ALTER TABLE node DROP CONSTRAINT IF EXISTS node_scope_vocab")

    repo.query!(
      "ALTER TABLE node ADD CONSTRAINT node_scope_vocab CHECK (scope " <>
        String.replace(@old_scope_check, "%s", "scope") <> ")"
    )

    repo.query!("ALTER TABLE edge DROP CONSTRAINT IF EXISTS edge_scope_vocab")

    repo.query!(
      "ALTER TABLE edge ADD CONSTRAINT edge_scope_vocab CHECK (visibility_scope " <>
        String.replace(@old_scope_check, "%s", "visibility_scope") <> ")"
    )

    repo.query!("ALTER TABLE group_role DROP CONSTRAINT IF EXISTS group_role_vocab")

    repo.query!(
      "ALTER TABLE group_role ADD CONSTRAINT group_role_vocab CHECK (role IN ('user','admin','superadmin'))"
    )

    :ok
  end

  defp recreate_old_tables!(repo) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS group_scope_map (
      group_id text PRIMARY KEY REFERENCES access_group(id) ON DELETE CASCADE,
      scopes text[] NOT NULL DEFAULT '{}'::text[]
    )
    """)

    repo.query!("""
    CREATE TABLE IF NOT EXISTS role_grant (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
      role text NOT NULL CONSTRAINT role_grant_role_vocab CHECK (role IN ('admin','superadmin')),
      source text NOT NULL CONSTRAINT role_grant_source_vocab CHECK (source IN ('direct','group','sso_group')),
      granted_by uuid,
      granted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS role_grant_user_id_role_source_index ON role_grant (user_id, role, source)"
    )

    :ok
  end

  # Old grants from the reconstructed Projects' GROUP members (user memberships have no
  # representation in the old model — logged, never widened into a group grant).
  defp rebuild_grants!(repo) do
    rows =
      repo.query!("""
      SELECT pm.group_id, s.label
        FROM project_membership pm
        JOIN source s ON s.project_id = pm.project_id
       WHERE pm.group_id IS NOT NULL AND s.origin = 'migration'
      """).rows

    rows
    |> Enum.group_by(&hd/1, fn [_g, label] ->
      if label == "legacy", do: "group", else: "src:" <> label
    end)
    |> Enum.each(fn {group, scopes} ->
      repo.query!(
        """
        INSERT INTO group_scope_map (group_id, scopes) VALUES ($1, $2)
        ON CONFLICT (group_id) DO UPDATE SET scopes = EXCLUDED.scopes
        """,
        [group, Enum.uniq(scopes)]
      )
    end)

    [[users]] =
      repo.query!("SELECT count(*)::int FROM project_membership WHERE user_id IS NOT NULL").rows

    if users > 0,
      do:
        IO.puts(
          "project_access down: #{users} direct user membership(s) have no old-model grant — dropped (fail-closed)"
        )

    :ok
  end
end
