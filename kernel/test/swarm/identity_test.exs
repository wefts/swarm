defmodule Swarm.IdentityTest do
  @moduledoc """
  Workspace ADR-16 step 1 + ADR-20 — the kernel identity store. The kernel owns the
  minimal authorization record (uuid + login + emails + identity-links + fixed-group and
  Project memberships). JIT-provisioned from *already-verified* claims; the store is the
  sole record of who-may-do-what. Scopes derive from Projects, roles from the fixed groups,
  `superadmin` only from a live elevation.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.Projects

  # A representative set of verified OIDC-shaped claims (the shape step 2 hands in).
  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        provider: "keycloak",
        subject: "sub-penta-0001",
        login: "penta",
        first_name: "Pentti",
        last_name: "Tester",
        nickname: nil,
        emails: [%{email: "penta@example.test", verified: true, primary: true}],
        groups: ["DSI"]
      },
      overrides
    )
  end

  describe "uuid7/0" do
    test "generates a syntactically valid, version-7 UUID" do
      u = Identity.uuid7()

      assert u =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      refute Identity.uuid7() == u
    end

    test "is time-ordered: a uuid minted in a later millisecond sorts after an earlier one" do
      a = Identity.uuid7()
      Process.sleep(2)
      b = Identity.uuid7()
      assert a < b
    end
  end

  describe "the fixed groups (ADR-20 D7)" do
    test "wheel / admins / staff exist; admins confers admin; nothing else is a group" do
      assert Identity.fixed_groups() == ["wheel", "admins", "staff"]
      assert Enum.map(Identity.list_groups(), & &1.id) == ["admins", "staff", "wheel"]
      assert Enum.find(Identity.list_groups(), &(&1.id == "admins")).granted_roles == ["admin"]
      assert Enum.find(Identity.list_groups(), &(&1.id == "wheel")).granted_roles == []
      assert Enum.find(Identity.list_groups(), &(&1.id == "staff")).granted_roles == []
      # a group grants NO scopes — there is no scope column any more
      refute Map.has_key?(hd(Identity.list_groups()), :granted_scopes)
    end

    test "add_to_group: unknown group refused; wheel takes local-only users" do
      {:ok, sso} = Identity.upsert_from_claims(claims())
      assert Identity.add_to_group(sso.id, "ops") == {:error, :unknown_group}
      assert Identity.add_to_group(sso.id, "wheel") == {:error, :wheel_local_only}
      assert :ok = Identity.add_to_group(sso.id, "admins")
      assert "admins" in Identity.groups_for(sso.id)

      {:ok, local} = Identity.invite_user(%{login: "loc"})
      assert :ok = Identity.add_to_group(local.id, "wheel")
      assert Identity.wheel_member?(local.id)
    end

    test "only admin is a bindable group role; superadmin never is" do
      assert Identity.set_group_role("staff", "superadmin") == {:error, :invalid_role}
      assert Identity.set_group_role("staff", "user") == {:error, :invalid_role}
      assert Identity.set_group_role("nope", "admin") == {:error, :unknown_group}
      assert :ok = Identity.set_group_role("staff", "admin")
      assert :ok = Identity.clear_group_role("staff", "admin")
    end
  end

  describe "upsert_from_claims/1 — JIT provisioning" do
    test "creates a new active user with login, names, email, and joins the default cohort" do
      assert {:ok, u} = Identity.upsert_from_claims(claims())

      assert u.login == "penta"
      assert u.first_name == "Pentti"
      assert u.status == "active"
      assert u.external == false
      assert u.id =~ ~r/^[0-9a-f-]{36}$/

      assert [%{email: "penta@example.test", is_primary: true} = e] = Identity.emails_for(u.id)
      assert e.verified_at != nil

      # the default internal cohort (staff) — an unmapped IdP group grants nothing else
      assert Identity.groups_for(u.id) == ["staff"]
    end

    test "is idempotent on (provider, subject): a second login resolves to the SAME uuid" do
      {:ok, u1} = Identity.upsert_from_claims(claims())
      {:ok, u2} = Identity.upsert_from_claims(claims())
      assert u1.id == u2.id
      assert Identity.count_users() == 1
    end

    test "updates mutable attributes and last_login_at on re-login" do
      {:ok, u1} = Identity.upsert_from_claims(claims())
      first_login = Identity.get_user(u1.id).last_login_at

      {:ok, u2} = Identity.upsert_from_claims(claims(%{first_name: "Penny"}))
      assert u2.id == u1.id
      assert u2.first_name == "Penny"
      assert first_login != nil
      assert DateTime.compare(Identity.get_user(u2.id).last_login_at, first_login) != :lt
    end

    test "matches on stable subject, not login: a renamed login stays one uuid" do
      {:ok, u1} = Identity.upsert_from_claims(claims())
      {:ok, u2} = Identity.upsert_from_claims(claims(%{login: "penta2"}))
      assert u2.id == u1.id
      assert Identity.by_login("penta") == nil
      assert Identity.by_login("penta2").id == u1.id
    end

    test "the default cohort survives an IdP re-sync that drops every mapped group" do
      :ok = Identity.put_sso_group_map("keycloak", "DSI", "admins")
      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["DSI"]}))
      assert Enum.sort(Identity.groups_for(u.id)) == ["admins", "staff"]

      {:ok, _} = Identity.upsert_from_claims(claims(%{groups: []}))
      # the idp-sourced membership is revoked (default-deny); the default cohort is not
      assert Identity.groups_for(u.id) == ["staff"]
    end

    test "with no default cohort configured, a fresh user holds no group at all" do
      prev = Application.get_env(:swarm, :identity)
      Application.put_env(:swarm, :identity, Keyword.put(prev || [], :default_cohort, ""))
      on_exit(fn -> Application.put_env(:swarm, :identity, prev) end)

      {:ok, u} = Identity.upsert_from_claims(claims())
      assert Identity.groups_for(u.id) == []
      assert Identity.scopes_for(u.id) == ["public"]
    end
  end

  describe "SSO group mapping (default-deny; wheel unreachable)" do
    test "a mapped incoming group confers the kernel group and its role" do
      :ok = Identity.put_sso_group_map("keycloak", "DSI", "admins")

      {:ok, u} =
        Identity.upsert_from_claims(
          claims(%{subject: "sub-admin-0001", login: "admin1", groups: ["DSI"]})
        )

      assert Enum.sort(Identity.groups_for(u.id)) == ["admins", "staff"]
      assert Identity.roles_for(u.id) == ["admin"]
      assert "manage_access" in Identity.caps_for(u.id)
    end

    test "an unmapped incoming group grants nothing beyond the cohort" do
      {:ok, u} =
        Identity.upsert_from_claims(
          claims(%{subject: "sub-random-0001", login: "random1", groups: ["random-kc-group"]})
        )

      assert Identity.groups_for(u.id) == ["staff"]
      assert Identity.roles_for(u.id) == []
      assert Identity.scopes_for(u.id) == ["public"]
    end

    test "wheel is never an SSO target; an unknown group is refused" do
      assert Identity.put_sso_group_map("keycloak", "root", "wheel") ==
               {:error, :wheel_not_mappable}

      assert Identity.put_sso_group_map("keycloak", "DSI", "missing") == {:error, :unknown_group}
      assert Identity.list_sso_group_map() == []
    end

    test "a raw sso_group_map row targeting wheel is ignored at sync (belt)" do
      Repo.query!(
        "INSERT INTO sso_group_map (provider, incoming_group, our_group_id) VALUES ('keycloak', 'root', 'wheel')"
      )

      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["root"]}))
      refute "wheel" in Identity.groups_for(u.id)
    end

    test "put, list and delete sso group maps" do
      :ok = Identity.put_sso_group_map("keycloak", "DSI", "admins")

      assert Identity.list_sso_group_map() == [
               %{provider: "keycloak", incoming_group: "DSI", our_group_id: "admins"}
             ]

      assert :ok = Identity.delete_sso_group_map("keycloak", "DSI")
      assert Identity.list_sso_group_map() == []
    end
  end

  describe "scope derivation (Projects only, ADR-20)" do
    test "no membership ⇒ exactly the authenticated public baseline" do
      {:ok, u} = Identity.upsert_from_claims(claims())
      assert Identity.scopes_for(u.id) == ["public"]
    end

    test "the cohort's Project membership confers its Sources; a direct membership adds more" do
      internal = register_source!(name: "Internal", members: [%{group_id: "staff"}])
      {:ok, u} = Identity.upsert_from_claims(claims())
      assert Identity.scopes_for(u.id) == ["public", internal]

      extra = register_source!(name: "Ops", kind: "iac", members: [%{user_id: u.id}])
      assert Enum.sort(Identity.scopes_for(u.id)) == Enum.sort(["public", internal, extra])
    end

    test "private never enters the derived set — even for a real Project member" do
      {:ok, u} = Identity.upsert_from_claims(claims())
      scope = register_source!(name: "Internal", members: [%{user_id: u.id}])
      assert Identity.scopes_for(u.id) == ["public", scope]
      refute "private" in Identity.scopes_for(u.id)
    end

    test "a leftover non-fixed group row confers nothing and cannot be joined or SSO-mapped" do
      Repo.query!(
        "INSERT INTO access_group (id, source, name) VALUES ('legacy', 'idp', 'Legacy')"
      )

      {:ok, u} = Identity.upsert_from_claims(claims())
      assert Identity.add_to_group(u.id, "legacy") == {:error, :unknown_group}
      assert Identity.put_sso_group_map("keycloak", "L", "legacy") == {:error, :unknown_group}

      assert Projects.add_member(hd([Projects.create_project(%{name: "P"}) |> elem(1)]).id, %{
               group_id: "legacy"
             }) ==
               {:error, :unknown_group}
    end
  end

  describe "seed_wheel/1 — the bootstrap Wheel member" do
    test "creates a local active user in wheel + admins (+ the cohort), idempotently, with no standing superadmin" do
      vanity = "01920000-0000-7000-8000-00000000da7a"
      assert {:ok, u} = Identity.seed_wheel(%{id: vanity, login: "rootuser"})
      assert u.id == vanity and u.status == "active"
      assert Enum.sort(Identity.groups_for(u.id)) == ["admins", "staff", "wheel"]
      assert Identity.roles_for(u.id) == ["admin"]
      refute "read_any_conversation" in Identity.caps_for(u.id)
      assert Identity.local_only?(u.id)
      assert Identity.active_local_wheel_count() == 1

      assert {:ok, u2} = Identity.seed_wheel(%{id: vanity, login: "rootuser"})
      assert u2.id == vanity
      assert Identity.count_users() == 1
    end
  end

  describe "roles and capabilities (default-deny; group-derived; superadmin = elevation)" do
    test "a fresh user holds no roles; admins membership confers admin caps only" do
      {:ok, u} = Identity.upsert_from_claims(claims())
      assert Identity.roles_for(u.id) == []
      assert Identity.caps_for(u.id) == []

      :ok = Identity.add_to_group(u.id, "admins")
      assert Identity.roles_for(u.id) == ["admin"]
      assert Identity.caps_for(u.id) == Enum.sort(Identity.admin_caps())
      refute "manage_wheel" in Identity.caps_for(u.id)
      refute "read_any_conversation" in Identity.caps_for(u.id)
    end

    test "list_roles: superadmin holders are the LIVE elevations, never a standing set" do
      {:ok, _} = Identity.seed_wheel(%{id: Identity.uuid7(), login: "rootuser"})
      roles = Identity.list_roles()
      assert Enum.find(roles, &(&1.name == "admin")).holder_count == 1
      assert Enum.find(roles, &(&1.name == "superadmin")).holder_count == 0
      assert "read_any_conversation" in Enum.find(roles, &(&1.name == "superadmin")).capabilities
      assert Enum.find(roles, &(&1.name == "user")).holder_count == 0
    end
  end

  describe "invite / deactivate / delete" do
    test "invite creates an invited local user with a local link; a guest skips the cohort" do
      {:ok, u} = Identity.invite_user(%{login: "newbie", first_name: "New"})
      assert u.status == "invited" and u.external == false
      assert Identity.user_by_link("local", "newbie").id == u.id
      assert Identity.groups_for(u.id) == ["staff"]

      {:ok, g} = Identity.invite_user(%{login: "visitor", external: true})
      assert g.external
      assert Identity.groups_for(g.id) == []
      assert Identity.external?(g.id)
    end

    test "deactivate/delete kill every authority source: groups, Project memberships, links" do
      internal = register_source!(name: "Internal")
      {:ok, u} = Identity.upsert_from_claims(claims())
      :ok = Identity.add_to_group(u.id, "admins")
      [p] = Projects.list_projects()
      :ok = Projects.add_member(p.id, %{user_id: u.id})
      assert internal in Identity.scopes_for(u.id)

      :ok = Identity.deactivate_user(u.id)
      assert Identity.get_user(u.id).status == "disabled"
      assert Identity.groups_for(u.id) == []
      assert Identity.roles_for(u.id) == []
      assert Identity.scopes_for(u.id) == ["public"]

      :ok = Identity.delete_user(u.id)
      assert Identity.get_user(u.id).status == "deleted"
      assert Identity.user_by_link("keycloak", "sub-penta-0001") == nil
      assert Identity.get_user_view(u.id) == nil
    end
  end

  describe "admin read models" do
    test "list_users aggregates group-derived roles, groups, providers and the guest flag" do
      {:ok, u} = Identity.upsert_from_claims(claims())
      :ok = Identity.add_to_group(u.id, "admins")
      {:ok, g} = Identity.invite_user(%{login: "visitor", external: true})

      {users, 2} = Identity.list_users()
      penta = Enum.find(users, &(&1.login == "penta"))
      assert penta.roles == ["admin"]
      assert Enum.sort(penta.groups) == ["admins", "staff"]
      assert penta.providers == ["keycloak"]
      refute penta.external
      assert Enum.find(users, &(&1.id == g.id)).external
    end

    test "get_user_view carries emails, groups, roles and visible Projects" do
      internal = register_source!(name: "Internal", members: [%{group_id: "staff"}])
      {:ok, u} = Identity.upsert_from_claims(claims())
      view = Identity.get_user_view(u.id)
      assert view.emails == ["penta@example.test"]
      assert view.groups == ["staff"]
      assert view.roles == []
      [pid] = view.projects
      assert Projects.get_project(pid).name == "Internal"
      assert Identity.scopes_for(u.id) == ["public", internal]
    end

    test "get_group lists members; local_only? distinguishes providers" do
      {:ok, u} = Identity.upsert_from_claims(claims())
      %{group: g, members: [m]} = Identity.get_group("staff")
      assert g.id == "staff" and g.member_count == 1
      assert m.login == "penta" and m.providers == ["keycloak"]
      refute Identity.local_only?(u.id)
      assert Identity.get_group("nope") == nil
    end
  end
end
