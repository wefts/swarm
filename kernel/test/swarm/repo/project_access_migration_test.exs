Code.require_file("../../../priv/repo/migrations/20260827090000_project_access.exs", __DIR__)

defmodule Swarm.Repo.ProjectAccessMigrationTest do
  @moduledoc """
  Workspace ADR-20 migration round-trip on a seeded ADR-18/19-shaped store: Projects are
  reconstructed from the grant signatures (census FIRST), legacy groups are folded into direct
  memberships, scopes are rewritten to `src:<uuid>`, every resolvable user's effective
  visibility is IDENTICAL before and after, break-glass survives, `down` restores the old
  shape, and the abort paths abort (and roll back).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.{Projects, Repo}
  alias Swarm.Repo.Migrations.ProjectAccess

  @root "01920000-0000-7000-8000-00000000da7a"
  @adm "01920000-0000-7000-8000-000000000ad0"
  @bob "01920000-0000-7000-8000-000000000b0b"
  @carol "01920000-0000-7000-8000-00000000ca01"
  @ghost "01920000-0000-7000-8000-0000000d0e5d"

  setup do
    Swarm.IdentityCase.truncate_identity()

    on_exit(fn ->
      # Re-migrate UNCONDITIONALLY: if a test died mid-way, wipe the old-shape identity data
      # first so the census cannot abort and pin the SHARED test DB at v10 (DDL survives TRUNCATE).
      try do
        ProjectAccess.apply_up!(Repo)
      rescue
        _ ->
          Repo.query!("TRUNCATE app_user, access_group RESTART IDENTITY CASCADE")
          ProjectAccess.apply_up!(Repo)
      end

      Swarm.IdentityCase.truncate_identity()
    end)

    :ok
  end

  # ── the old shape (ADR-18 grants + ADR-19 groups), raw SQL only ─────────────

  defp seed_old_shape! do
    :ok = ProjectAccess.apply_down!(Repo)
    Repo.query!("DELETE FROM group_role")
    Repo.query!("DELETE FROM sso_group_map")
    Repo.query!("DELETE FROM user_group")
    Repo.query!("DELETE FROM access_group")

    for {id, name} <- [
          {"superuser", "Superuser"},
          {"admins", "Admins"},
          {"everyone", "Everyone"}
        ] do
      Repo.query!("INSERT INTO access_group (id, source, name) VALUES ($1, 'local', $2)", [
        id,
        name
      ])
    end

    # a legacy IdP-mapped cohort (ADR-18 era): grants confluence to its members
    Repo.query!(
      "INSERT INTO access_group (id, source, name) VALUES ('confluence', 'idp', 'confluence')"
    )

    Repo.query!(
      "INSERT INTO group_role (group_id, role) VALUES ('superuser','superadmin'), ('admins','admin')"
    )

    all = ["src:wiki", "src:ldap", "src:confluence", "src:iac", "group"]

    for {g, scopes} <- [
          {"superuser", all},
          {"admins", all},
          {"everyone", ["src:wiki", "src:ldap"]},
          {"confluence", ["src:confluence"]}
        ] do
      Repo.query!("INSERT INTO group_scope_map (group_id, scopes) VALUES ($1, $2)", [g, scopes])
    end

    Repo.query!("""
    INSERT INTO sso_group_map (provider, incoming_group, our_group_id) VALUES
      ('keycloak', 'everyone', 'everyone'), ('keycloak', 'admins', 'admins'),
      ('keycloak', 'su', 'superuser'), ('keycloak', 'conf', 'confluence')
    """)

    for {id, login, status} <- [
          {@root, "groot", "active"},
          {@adm, "adm", "active"},
          {@bob, "bob", "active"},
          {@carol, "carol", "invited"},
          {@ghost, "ghost", "deleted"}
        ] do
      Repo.query!("INSERT INTO app_user (id, login, status) VALUES ($1, $2, $3)", [
        Ecto.UUID.dump!(id),
        login,
        status
      ])
    end

    Repo.query!(
      "INSERT INTO identity_link (user_id, provider, subject) VALUES ($1, 'local', 'groot')",
      [Ecto.UUID.dump!(@root)]
    )

    for {id, login} <- [{@adm, "adm"}, {@bob, "bob"}, {@carol, "carol"}] do
      Repo.query!(
        "INSERT INTO identity_link (user_id, provider, subject) VALUES ($1, 'keycloak', $2)",
        [Ecto.UUID.dump!(id), "sub-" <> login]
      )
    end

    for {id, g, src} <- [
          {@root, "superuser", "local"},
          {@adm, "admins", "idp"},
          {@bob, "everyone", "idp"},
          {@carol, "confluence", "idp"}
        ] do
      Repo.query!("INSERT INTO user_group (user_id, group_id, source) VALUES ($1, $2, $3)", [
        Ecto.UUID.dump!(id),
        g,
        src
      ])
    end

    nodes =
      for {key, scope} <- [
            {"wiki-a", "src:wiki"},
            {"wiki-b", "src:wiki"},
            {"ldap-a", "src:ldap"},
            {"conf-a", "src:confluence"},
            {"iac-a", "src:iac"},
            {"legacy-a", "group"},
            {"legacy-b", "group"},
            {"pub", "public"},
            {"priv", "private"}
          ],
          into: %{} do
        %{rows: [[id]]} =
          Repo.query!(
            "INSERT INTO node (type, key, scope) VALUES ('article', $1, $2) RETURNING id",
            [key, scope]
          )

        {key, id}
      end

    Repo.query!("INSERT INTO chunk (node_id, ordinal, text) VALUES ($1, 0, 'body')", [
      nodes["wiki-a"]
    ])

    for {a, b, scope} <- [
          {"wiki-a", "wiki-b", "src:wiki"},
          {"wiki-a", "ldap-a", "private"},
          {"legacy-a", "legacy-b", "group"}
        ] do
      Repo.query!(
        "INSERT INTO edge (src, dst, type, visibility_scope, seen_count) VALUES ($1, $2, 'mentions', $3, 1)",
        [nodes[a], nodes[b], scope]
      )
    end

    nodes
  end

  defp scope_of(key) do
    Repo.query!("SELECT scope FROM node WHERE key = $1", [key]).rows |> hd() |> hd()
  end

  defp groups_of(id) do
    Repo.query!("SELECT group_id FROM user_group WHERE user_id = $1 ORDER BY 1", [
      Ecto.UUID.dump!(id)
    ]).rows
    |> List.flatten()
  end

  defp source_scope!(label) do
    %{rows: [[id]]} = Repo.query!("SELECT id::text FROM source WHERE label = $1", [label])
    "src:" <> id
  end

  defp project_of_source(label) do
    %{rows: [[name, vis]]} =
      Repo.query!(
        "SELECT p.name, p.visibility FROM source s JOIN project p ON p.id = s.project_id WHERE s.label = $1",
        [label]
      )

    {name, vis}
  end

  defp project_group_members(name) do
    Repo.query!(
      """
      SELECT pm.group_id FROM project_membership pm JOIN project p ON p.id = pm.project_id
       WHERE p.name = $1 AND pm.group_id IS NOT NULL ORDER BY 1
      """,
      [name]
    ).rows
    |> List.flatten()
  end

  defp version do
    Repo.query!("SELECT version FROM graph_schema_meta WHERE id = 1").rows |> hd() |> hd()
  end

  defp table?(name), do: Repo.query!("SELECT to_regclass($1)", [name]).rows |> hd() |> hd() != nil

  # ── the round trip ────────────────────────────────────────────────────────

  test "up: grant signatures → Projects, legacy groups folded, uuid scopes, identical visibility, break-glass kept; down restores" do
    seed_old_shape!()
    assert version() == 10

    :ok = ProjectAccess.apply_up!(Repo)

    # fixed groups + moves; carol's legacy `confluence` group is FOLDED: only the fixed three remain
    assert groups_of(@root) == ["admins", "staff", "wheel"]
    assert groups_of(@adm) == ["admins", "staff"]
    assert groups_of(@bob) == ["staff"]
    assert groups_of(@carol) == ["staff"]
    assert groups_of(@ghost) == []

    assert Repo.query!("SELECT id FROM access_group ORDER BY id").rows == [
             ["admins"],
             ["staff"],
             ["wheel"]
           ]

    assert Repo.query!("SELECT group_id, role FROM group_role").rows == [["admins", "admin"]]

    # sso rows: everyone→staff re-pointed, superuser + the folded legacy group dropped
    assert Repo.query!("SELECT incoming_group, our_group_id FROM sso_group_map ORDER BY 1").rows ==
             [["admins", "admins"], ["everyone", "staff"]]

    # projects from the signatures: wiki/ldap ← {admins, staff} ⇒ Internal; iac/legacy ← {admins}
    # and confluence ← {admins, confluence} both lack staff ⇒ two "Operations" — the collision is
    # resolved by appending the sorted signature
    assert project_of_source("wiki") == {"Internal", "shared"}
    assert project_of_source("ldap") == {"Internal", "shared"}
    assert project_of_source("iac") == {"Operations (admins)", "shared"}
    assert project_of_source("legacy") == {"Operations (admins)", "shared"}
    assert project_of_source("confluence") == {"Operations (admins+confluence)", "shared"}
    assert project_group_members("Internal") == ["admins", "staff"]
    assert project_group_members("Operations (admins)") == ["admins"]
    # the folded group's membership became carol's DIRECT (migration) membership
    assert project_group_members("Operations (admins+confluence)") == ["admins"]

    assert Repo.query!(
             """
             SELECT pm.source FROM project_membership pm JOIN project p ON p.id = pm.project_id
              WHERE p.name = 'Operations (admins+confluence)' AND pm.user_id = $1
             """,
             [Ecto.UUID.dump!(@carol)]
           ).rows == [["migration"]]

    assert Repo.query!("SELECT DISTINCT origin FROM source").rows == [["migration"]]

    # scopes rewritten (node + edge + chunk mirror), nothing left at a label
    wiki = source_scope!("wiki")
    legacy = source_scope!("legacy")
    assert scope_of("wiki-a") == wiki and scope_of("wiki-b") == wiki
    assert scope_of("legacy-a") == legacy
    assert scope_of("pub") == "public" and scope_of("priv") == "private"
    assert Repo.query!("SELECT scope FROM chunk").rows == [[wiki]]

    assert Repo.query!("SELECT visibility_scope FROM edge ORDER BY 1").rows ==
             Enum.sort([[wiki], ["private"], [legacy]])

    assert Repo.query!("""
           SELECT count(*) FROM node
            WHERE scope NOT IN ('private','public')
              AND scope !~ '^src:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           """).rows == [[0]]

    # identical visibility, now derived from Projects (carol keeps confluence via the fold)
    all = Enum.sort(["public" | Enum.map(~w(wiki ldap confluence iac legacy), &source_scope!/1)])
    internal = Enum.sort(["public", source_scope!("wiki"), source_scope!("ldap")])
    assert Enum.sort(Swarm.Identity.scopes_for(@root)) == all
    assert Enum.sort(Swarm.Identity.scopes_for(@adm)) == all
    assert Enum.sort(Swarm.Identity.scopes_for(@bob)) == internal

    assert Enum.sort(Swarm.Identity.scopes_for(@carol)) ==
             Enum.sort([source_scope!("confluence") | internal])

    # no standing superadmin; groot is Wheel + admin; break-glass eligibility preserved
    assert Swarm.Identity.roles_for(@root) == ["admin"]
    refute "read_any_conversation" in Swarm.Identity.caps_for(@root)
    assert Swarm.Identity.active_local_wheel_count() == 1

    # the CHECK is tightened
    for bad <- ["src:wiki", "group"] do
      assert_raise Postgrex.Error, ~r/node_scope_vocab/, fn ->
        Repo.query!("INSERT INTO node (type, key, scope) VALUES ('article', $1, $2)", [
          "x-" <> bad,
          bad
        ])
      end
    end

    refute table?("public.group_scope_map")
    refute table?("public.role_grant")
    assert version() == 11

    # idempotent re-run
    :ok = ProjectAccess.apply_up!(Repo)
    assert Repo.query!("SELECT count(*) FROM project").rows == [[3]]

    # down: labels back, grants rebuilt from the group memberships, structure restored
    :ok = ProjectAccess.apply_down!(Repo)
    assert scope_of("wiki-a") == "src:wiki" and scope_of("legacy-a") == "group"
    assert Repo.query!("SELECT scope FROM chunk").rows == [["src:wiki"]]

    grants =
      Repo.query!("SELECT group_id, scopes FROM group_scope_map ORDER BY 1").rows
      |> Map.new(fn [g, s] -> {g, Enum.sort(s)} end)

    assert grants["staff"] == ["src:ldap", "src:wiki"]

    assert grants["admins"] ==
             Enum.sort(["src:wiki", "src:ldap", "src:confluence", "src:iac", "group"])

    # carol's direct membership has no old-model representation — dropped (fail-closed), logged
    refute Map.has_key?(grants, "confluence")
    refute table?("public.project")
    assert table?("public.role_grant")
    assert version() == 10
  end

  test "an orphan scope (granted to nobody) lands in Unassigned with NO members — fail-closed, flagged" do
    seed_old_shape!()
    Repo.query!("INSERT INTO node (type, key, scope) VALUES ('article', 'orphan', 'src:orphan')")

    :ok = ProjectAccess.apply_up!(Repo)

    assert project_of_source("orphan") == {"Unassigned", "shared"}
    assert project_group_members("Unassigned") == []
    refute source_scope!("orphan") in Swarm.Identity.scopes_for(@root)
  end

  test "aborts (rolls back) when no active local Wheel member would survive" do
    seed_old_shape!()
    # the only superadmin holder also carries an SSO link → not local-only → would lock out
    Repo.query!(
      "INSERT INTO identity_link (user_id, provider, subject) VALUES ($1, 'keycloak', 'sub-groot')",
      [Ecto.UUID.dump!(@root)]
    )

    assert_raise RuntimeError, ~r/lock out break-glass/, fn ->
      Repo.transaction(fn -> ProjectAccess.apply_up!(Repo) end)
    end

    # rolled back: the old model is intact
    assert table?("public.group_scope_map")
    assert scope_of("wiki-a") == "src:wiki"
    assert version() == 10

    # leave a migratable old-shape store for the on_exit re-apply (the lockout is the point of
    # THIS test, not of the teardown)
    Repo.query!("DELETE FROM identity_link WHERE provider = 'keycloak' AND user_id = $1", [
      Ecto.UUID.dump!(@root)
    ])
  end

  test "aborts (rolls back) when the reconstruction would CHANGE someone's visibility (exact equivalence)" do
    seed_old_shape!()
    # a configured baseline group `ops` (granting iac) DISTINCT from `everyone`: the old formula
    # gives every user ops' scopes but only everyone's MEMBERS its scopes; folding both into
    # `staff` would hand carol wiki+ldap she never had → widening → abort
    Repo.query!("INSERT INTO access_group (id, source, name) VALUES ('ops', 'local', 'Ops')")
    Repo.query!("INSERT INTO group_scope_map (group_id, scopes) VALUES ('ops', ARRAY['src:iac'])")
    Repo.query!("DELETE FROM user_group WHERE user_id = $1", [Ecto.UUID.dump!(@carol)])
    System.put_env("SWARM_AUTH_BASELINE_GROUP", "ops")

    try do
      assert_raise RuntimeError, ~r/effective scopes changed for carol/, fn ->
        Repo.transaction(fn -> ProjectAccess.apply_up!(Repo) end)
      end
    after
      System.delete_env("SWARM_AUTH_BASELINE_GROUP")
    end

    # rolled back: old model intact
    assert table?("public.group_scope_map")
    assert scope_of("wiki-a") == "src:wiki"
    assert version() == 10
  end

  test "down refuses while post-migration Sources exist (unless forced, which clamps them to private)" do
    seed_old_shape!()
    :ok = ProjectAccess.apply_up!(Repo)

    {:ok, p} = Projects.create_project(%{name: "New after cutover"})
    {:ok, s} = Projects.add_source(p.id, %{kind: "slack"})
    Store.upsert_node("article", "new-row", scope: s.scope)

    assert_raise RuntimeError, ~r/down refused/, fn -> ProjectAccess.apply_down!(Repo) end
    assert version() == 11

    System.put_env("SWARM_MIGRATION_FORCE_DOWN", "1")

    try do
      :ok = ProjectAccess.apply_down!(Repo)
    after
      System.delete_env("SWARM_MIGRATION_FORCE_DOWN")
    end

    assert scope_of("new-row") == "private"
    assert scope_of("wiki-a") == "src:wiki"
  end
end
