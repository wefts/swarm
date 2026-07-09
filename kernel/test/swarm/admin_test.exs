defmodule Swarm.AdminTest do
  @moduledoc """
  Workspace ADR-16 step 5 — access grants + user management, kernel-owned,
  admin-mutable, audited. Capabilities (derived from role_grant, default-deny):
  admin = {manage_access, invite_users, manage_users}; superadmin = all +
  read_any_conversation. Role grants are privilege management → superadmin-only.
  admin does NOT get chat-read (step 4) nor another user's own KB.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Admin, Audit, Conversations}
  alias Swarm.Core.Server

  alias Swarm.Core.V1.{
    ListGroupsRequest,
    ListSsoMapRequest,
    ManageGroupRequest,
    ManageSsoMapRequest
  }

  defp user(login, overrides \\ %{}) do
    {:ok, u} =
      Identity.upsert_from_claims(
        Map.merge(
          %{
            provider: "keycloak",
            subject: "sub-#{login}",
            login: login,
            groups: []
          },
          overrides
        )
      )

    u
  end

  defp superadmin do
    {:ok, u} =
      Identity.seed_superadmin(%{
        id: Identity.uuid7(),
        login: "root#{System.unique_integer([:positive])}"
      })

    u.id
  end

  defp assertion(login), do: Actor.sign(%{"sub" => "sub-#{login}", "provider" => "keycloak"})
  defp local_assertion(login), do: Actor.sign(%{"sub" => login, "provider" => "local"})

  defp admin_user(login) do
    u = user(login)
    :ok = Admin.grant_role(superadmin(), u.id, "admin")
    u
  end

  defp put_map(token, provider, incoming, group) do
    Server.manage_sso_map(
      %ManageSsoMapRequest{
        assertion: token,
        op: :SSO_MAP_PUT,
        provider: provider,
        incoming_group: incoming,
        our_group_id: group
      },
      nil
    )
  end

  describe "role grants (superadmin-only — privilege management)" do
    test "a superadmin grants and revokes the admin role, audited" do
      root = superadmin()
      u = user("penta")
      assert :ok = Admin.grant_role(root, u.id, "admin")
      assert "admin" in Identity.roles_for(u.id)
      assert Enum.any?(Audit.for_actor(root), &(&1.action == "grant"))

      assert :ok = Admin.revoke_role(root, u.id, "admin")
      refute "admin" in Identity.roles_for(u.id)
      assert Enum.any?(Audit.for_actor(root), &(&1.action == "revoke"))
    end

    test "a plain admin cannot grant roles (no self-escalation) — :not_authorized, audited" do
      admin = admin_user("adm")
      victim = user("victim")
      assert Admin.grant_role(admin.id, victim.id, "superadmin") == :not_authorized
      refute "superadmin" in Identity.roles_for(victim.id)
      assert Enum.any?(Audit.for_actor(admin.id), &(&1.decision == "denied"))
    end
  end

  describe "manage_access — group membership + scope map (shared-resource access)" do
    test "an admin adds a user to a group and maps the group's scopes; access is conferred" do
      admin = admin_user("adm")
      u = user("penta")
      assert :ok = Admin.set_group_scopes(admin.id, "nebula", ["public", "group"])
      assert :ok = Admin.grant_group(admin.id, u.id, "nebula")
      assert Enum.sort(Identity.scopes_for(u.id)) == ["group", "public"]
      assert :ok = Admin.revoke_group(admin.id, u.id, "nebula")
      assert Identity.scopes_for(u.id) == ["public"]
    end

    test "a user without manage_access cannot change access — :not_authorized" do
      mallory = user("mallory")
      u = user("penta")
      assert Admin.grant_group(mallory.id, u.id, "nebula") == :not_authorized
      assert Admin.set_group_scopes(mallory.id, "nebula", ["group"]) == :not_authorized
    end

    test "even an admin cannot grant private — rejected, audited, nothing conferred" do
      admin = admin_user("adm")
      u = user("penta")
      :ok = Admin.grant_group(admin.id, u.id, "nebula")

      assert Admin.set_group_scopes(admin.id, "nebula", ["group", "private"]) ==
               {:error, :ungrantable_scope}

      assert Identity.scopes_for(u.id) == ["public"]
      assert Enum.any?(Audit.for_actor(admin.id), &(&1.decision == "denied"))
    end
  end

  describe "invite_users" do
    test "an admin invites a local user (status invited, local link), audited" do
      admin = admin_user("adm")
      assert {:ok, u} = Admin.invite_user(admin.id, %{login: "newbie", first_name: "New"})
      assert u.status == "invited"
      assert Identity.by_login("newbie").id == u.id
      # a local identity_link exists so the channel can set a password + they can log in
      assert Identity.user_by_link("local", "newbie").id == u.id
      assert Enum.any?(Audit.for_actor(admin.id), &(&1.action == "invite"))
    end

    test "a user without invite_users cannot invite — :not_authorized" do
      mallory = user("mallory")
      assert Admin.invite_user(mallory.id, %{login: "x"}) == :not_authorized
      assert Identity.by_login("x") == nil
    end
  end

  describe "list_users — the admin-console roster (admin-cleanup epic)" do
    test "an admin lists users: uuid, status, roles, groups, providers; login-ordered" do
      admin = admin_user("lister")
      _u = user("bravo")
      _u2 = user("alpha")

      assert {:ok, {users, total}} = Admin.list_users(admin.id)
      logins = Enum.map(users, & &1.login)
      assert "alpha" in logins and "bravo" in logins
      assert total == length(users)
      # deterministic order (login, id)
      assert logins == Enum.sort(logins)

      me = Enum.find(users, &(&1.login == "lister"))
      # the uuid ManageUser/ManageAccess actually target
      assert me.id == admin.id
      assert me.status == "active"
      assert "admin" in me.roles
      assert "keycloak" in me.providers
    end

    test "a plain user is denied AND the denial is audited; success is NOT audited" do
      plain = user("nobody")
      assert Admin.list_users(plain.id) == :not_authorized
      assert Admin.get_user(plain.id, plain.id) == :not_authorized

      assert Enum.any?(
               Audit.for_actor(plain.id),
               &(&1.action == "list_users" and &1.decision == "denied")
             )

      assert Enum.any?(
               Audit.for_actor(plain.id),
               &(&1.action == "get_user" and &1.decision == "denied")
             )

      admin = admin_user("quiet")
      before = length(Audit.for_actor(admin.id))
      assert {:ok, _} = Admin.list_users(admin.id)
      # roster reads don't drown the audit
      assert length(Audit.for_actor(admin.id)) == before
    end

    test "deleted users are tombstoned out unless explicitly included" do
      root = superadmin()
      ghost = user("ghost")
      :ok = Admin.delete_user(root, ghost.id)

      assert {:ok, {users, _total}} = Admin.list_users(root)
      refute Enum.any?(users, &(&1.login == "ghost"))

      assert {:ok, {all, _total}} = Admin.list_users(root, include_deleted: true)
      g = Enum.find(all, &(&1.login == "ghost"))
      assert g && g.status == "deleted"
    end

    test "search filters server-side and total reflects the filtered count" do
      admin = admin_user("lister")
      _u = user("haystack")
      _u2 = user("needle", %{first_name: "Ariadne"})
      _u3 = user("another")

      assert {:ok, {users, 1}} = Admin.list_users(admin.id, query: "ARI")
      assert Enum.map(users, & &1.login) == ["needle"]
    end

    test "limit and offset page the filtered roster while total stays pre-page" do
      admin = admin_user("pager")
      _u = user("page-alpha")
      _u2 = user("page-bravo")

      assert {:ok, {first_page, 2}} = Admin.list_users(admin.id, query: "page-", limit: 1)
      assert Enum.map(first_page, & &1.login) == ["page-alpha"]

      assert {:ok, {second_page, 2}} =
               Admin.list_users(admin.id, query: "page-", limit: 1, offset: 1)

      assert Enum.map(second_page, & &1.login) == ["page-bravo"]
    end

    test "LIKE metacharacters in search are treated literally" do
      admin = admin_user("literal")
      _u = user("under_score")
      _u2 = user("underXscore")

      assert {:ok, {users, 1}} = Admin.list_users(admin.id, query: "_")
      assert Enum.map(users, & &1.login) == ["under_score"]
    end

    test "get_user returns the aggregated detail view with emails" do
      admin = admin_user("detail-admin")
      :ok = Identity.create_group("staff", "staff", nil)
      :ok = Identity.put_sso_group_map("keycloak", "staff", "staff")

      u =
        user("detail-target", %{
          emails: [
            %{email: "target-secondary@example.test", verified: true, primary: false},
            %{email: "target@example.test", verified: true, primary: true}
          ],
          groups: ["staff"]
        })

      assert {:ok, view} = Admin.get_user(admin.id, u.id)
      assert view.id == u.id
      assert view.login == "detail-target"
      assert view.groups == ["staff"]
      assert view.providers == ["keycloak"]
      # Order is DB-collation dependent (not a contract) — assert the set.
      assert Enum.sort(view.emails) ==
               Enum.sort(["target-secondary@example.test", "target@example.test"])
    end

    test "get_user returns :not_found for unknown and tombstoned users" do
      root = superadmin()
      ghost = user("detail-ghost")

      assert Admin.get_user(root, Identity.uuid7()) == :not_found

      :ok = Admin.delete_user(root, ghost.id)
      assert Admin.get_user(root, ghost.id) == :not_found
    end
  end

  describe "list_groups — the admin-console group read model" do
    test "members-only and scopes-only groups both appear with counts, scopes, and empty roles" do
      admin = admin_user("group-reader")
      u1 = user("group-member-a")
      u2 = user("group-member-b")

      :ok = Identity.add_to_group(u1.id, "members-only")
      :ok = Identity.add_to_group(u2.id, "members-only")
      :ok = Identity.put_group_scopes("scopes-only", ["public"])

      assert {:ok, groups} = Admin.list_groups(admin.id)

      members_only = Enum.find(groups, &(&1.id == "members-only"))
      assert members_only.name == nil
      assert members_only.description == nil
      assert members_only.member_count == 2
      assert members_only.granted_scopes == []
      assert members_only.granted_roles == []

      scopes_only = Enum.find(groups, &(&1.id == "scopes-only"))
      assert scopes_only.name == nil
      assert scopes_only.description == nil
      assert scopes_only.member_count == 0
      assert scopes_only.granted_scopes == ["public"]
      assert scopes_only.granted_roles == []
    end

    test "a plain user is denied and the denial is audited" do
      plain = user("group-denied")

      assert Admin.list_groups(plain.id) == :not_authorized

      assert Enum.any?(
               Audit.for_actor(plain.id),
               &(&1.action == "list_groups" and &1.decision == "denied")
             )
    end
  end

  describe "manage_group — first-class group lifecycle" do
    test "create and rename surface through ListGroups with name and description; scopes confer" do
      admin = admin_user("group-manager")
      token = assertion("group-manager")

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_CREATE,
                 group_id: "ops",
                 name: "Operations",
                 description: "Operational access"
               },
               nil
             ).status == :CALL_OK

      listed = Server.list_groups(%ListGroupsRequest{assertion: token}, nil)
      assert listed.status == :CALL_OK
      created = Enum.find(listed.groups, &(&1.id == "ops"))
      assert created.name == "Operations"
      assert created.description == "Operational access"

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_RENAME,
                 group_id: "ops",
                 name: "Platform Ops"
               },
               nil
             ).status == :CALL_OK

      renamed =
        Server.list_groups(%ListGroupsRequest{assertion: token}, nil).groups
        |> Enum.find(&(&1.id == "ops"))

      assert renamed.name == "Platform Ops"
      assert renamed.description == "Operational access"

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_SET_SCOPES,
                 group_id: "ops",
                 scopes: ["public", "src:wiki"]
               },
               nil
             ).status == :CALL_OK

      u = user("ops-member")
      assert :ok = Admin.grant_group(admin.id, u.id, "ops")
      assert Enum.sort(Identity.scopes_for(u.id)) == ["public", "src:wiki"]
    end

    test "a group-conferred admin role gives a plain member admin capabilities" do
      root = superadmin()
      u = user("group-role-member")

      assert :ok = Admin.create_group(root, "operators", "Operators", nil)
      assert :ok = Admin.set_group_role(root, "operators", "admin")
      assert :ok = Admin.grant_group(root, u.id, "operators")

      assert "admin" in Identity.roles_for(u.id)
      assert "manage_access" in Identity.caps_for(u.id)
      assert "invite_users" in Identity.caps_for(u.id)
      assert "manage_users" in Identity.caps_for(u.id)
    end

    test "group role operations are superadmin-only and denials are audited" do
      root = superadmin()
      admin = admin_user("group-role-admin")

      assert :ok = Admin.create_group(root, "privileged", "Privileged", nil)
      assert Admin.set_group_role(admin.id, "privileged", "admin") == :not_authorized
      assert Admin.clear_group_role(admin.id, "privileged", "admin") == :not_authorized

      rows = Audit.for_actor(admin.id)
      assert Enum.any?(rows, &(&1.action == "set_group_role" and &1.decision == "denied"))
      assert Enum.any?(rows, &(&1.action == "clear_group_role" and &1.decision == "denied"))
    end

    test "non-empty delete requires confirm, and confirmed delete cascades membership" do
      admin = admin_user("group-delete-admin")
      u = user("group-delete-member")

      assert :ok = Admin.create_group(admin.id, "doomed", "Doomed", nil)
      assert :ok = Admin.set_group_scopes(admin.id, "doomed", ["src:wiki"])
      assert :ok = Admin.grant_group(admin.id, u.id, "doomed")

      assert Admin.delete_group(admin.id, "doomed", false) == :not_confirmed

      assert Enum.any?(
               Audit.for_actor(admin.id),
               &(&1.action == "delete_group" and &1.decision == "denied" and
                   &1.reason == "not_confirmed")
             )

      assert Identity.group_exists?("doomed")

      assert Admin.delete_group(admin.id, "doomed", true) == :ok
      refute Identity.group_exists?("doomed")
      refute "doomed" in Identity.groups_for(u.id)
    end

    test "a non-admin ManageGroup request is NOT_AUTHORIZED and audited" do
      plain = user("group-rpc-denied")

      resp =
        Server.manage_group(
          %ManageGroupRequest{
            assertion: assertion("group-rpc-denied"),
            op: :GROUP_CREATE,
            group_id: "blocked",
            name: "Blocked"
          },
          nil
        )

      assert resp.status == :CALL_NOT_AUTHORIZED

      assert Enum.any?(
               Audit.for_actor(plain.id),
               &(&1.action == "create_group" and &1.decision == "denied")
             )

      refute Identity.group_exists?("blocked")
    end

    test "ListGroups includes granted_roles after ManageGroup SET_ROLE" do
      root = superadmin()
      token = local_assertion(Identity.get_user(root).login)

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_CREATE,
                 group_id: "role-backed",
                 name: "Role-backed"
               },
               nil
             ).status == :CALL_OK

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_SET_ROLE,
                 group_id: "role-backed",
                 role: "admin"
               },
               nil
             ).status == :CALL_OK

      listed = Server.list_groups(%ListGroupsRequest{assertion: token}, nil)
      group = Enum.find(listed.groups, &(&1.id == "role-backed"))
      assert group.granted_roles == ["admin"]
    end
  end

  describe "SSO group mapping — list_sso_map / manage_sso_map (ADR-18 ps-4)" do
    test "put/upsert/delete/list round-trip through the RPC, ordered provider then incoming" do
      root = superadmin()
      _admin = admin_user("sso-map-admin")
      token = assertion("sso-map-admin")
      assert :ok = Admin.create_group(root, "staff", "Staff", nil)
      assert :ok = Admin.create_group(root, "ops", "Ops", nil)

      for {provider, incoming, group} <- [
            {"keycloak", "DSI", "ops"},
            {"keycloak", "All-Staff", "staff"},
            {"okta", "Everyone", "staff"}
          ] do
        assert put_map(token, provider, incoming, group).status == :CALL_OK
      end

      listed = Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil)
      assert listed.status == :CALL_OK

      assert Enum.map(listed.mappings, &{&1.provider, &1.incoming_group, &1.our_group_id}) ==
               [
                 {"keycloak", "All-Staff", "staff"},
                 {"keycloak", "DSI", "ops"},
                 {"okta", "Everyone", "staff"}
               ]

      # re-PUT re-points an existing (provider, incoming) pair — upsert, not a dup
      assert put_map(token, "keycloak", "DSI", "staff").status == :CALL_OK
      after_upsert = Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil).mappings
      assert length(after_upsert) == 3
      assert Enum.find(after_upsert, &(&1.incoming_group == "DSI")).our_group_id == "staff"

      assert Server.manage_sso_map(
               %ManageSsoMapRequest{
                 assertion: token,
                 op: :SSO_MAP_DELETE,
                 provider: "keycloak",
                 incoming_group: "DSI"
               },
               nil
             ).status == :CALL_OK

      remaining =
        Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil).mappings
        |> Enum.map(& &1.incoming_group)

      refute "DSI" in remaining
      assert length(remaining) == 2
    end

    test "PUT onto a non-existent group is BAD_REQUEST and maps nothing" do
      _admin = admin_user("sso-map-unknown")
      token = assertion("sso-map-unknown")

      assert put_map(token, "keycloak", "Ghost", "no-such-group").status == :CALL_BAD_REQUEST
      assert Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil).mappings == []
    end

    test "an empty required field is BAD_REQUEST (no half-written mapping)" do
      root = superadmin()
      _admin = admin_user("sso-map-empty")
      token = assertion("sso-map-empty")
      assert :ok = Admin.create_group(root, "staff", "Staff", nil)

      assert put_map(token, "keycloak", "", "staff").status == :CALL_BAD_REQUEST
      assert Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil).mappings == []
    end

    test "a non-admin is NOT_AUTHORIZED for list and manage, and denials are audited" do
      plain = user("sso-map-denied")
      token = assertion("sso-map-denied")

      assert Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil).status ==
               :CALL_NOT_AUTHORIZED

      assert put_map(token, "keycloak", "X", "staff").status == :CALL_NOT_AUTHORIZED

      rows = Audit.for_actor(plain.id)
      assert Enum.any?(rows, &(&1.action == "list_sso_map" and &1.decision == "denied"))
      assert Enum.any?(rows, &(&1.action == "put_sso_map" and &1.decision == "denied"))
    end
  end

  describe "list_roles — the admin-console role read model" do
    test "known roles include derived capabilities and distinct explicit holder counts" do
      admin = admin_user("role-reader")
      admin_two = user("admin-two")
      root = superadmin()
      :ok = Admin.grant_role(root, admin_two.id, "admin")

      assert {:ok, roles} = Admin.list_roles(admin.id)

      user_role = Enum.find(roles, &(&1.name == "user"))
      assert user_role.capabilities == []
      assert user_role.holder_count == 0

      admin_role = Enum.find(roles, &(&1.name == "admin"))
      assert admin_role.capabilities == Identity.caps_for(admin.id)
      assert admin_role.holder_count == 2

      superadmin_role = Enum.find(roles, &(&1.name == "superadmin"))
      assert "read_any_conversation" in superadmin_role.capabilities
      assert superadmin_role.holder_count == 2
    end

    test "a plain user is denied and the denial is audited" do
      plain = user("role-denied")

      assert Admin.list_roles(plain.id) == :not_authorized

      assert Enum.any?(
               Audit.for_actor(plain.id),
               &(&1.action == "list_roles" and &1.decision == "denied")
             )
    end
  end

  describe "manage_users — deactivate / delete (auth dies, learned content persists)" do
    test "deactivate disables login and strips role grants; learned content stays" do
      admin = admin_user("adm")
      u = user("penta")
      :ok = Admin.grant_role(superadmin(), u.id, "admin")
      {:ok, c} = Conversations.create(u.id, %{title: "theirs"})

      assert :ok = Admin.deactivate_user(admin.id, u.id)
      assert Identity.get_user(u.id).status == "disabled"
      assert Identity.roles_for(u.id) == []
      # the account's conversation persists (D11 — not right-to-erasure)
      assert {:ok, _} = Conversations.get(u.id, c.id)
      assert Enum.any?(Audit.for_actor(admin.id), &(&1.action == "deactivate"))
    end

    test "delete kills every login path (status deleted, no identity_link) but keeps content" do
      admin = admin_user("adm")
      u = user("penta")
      {:ok, c} = Conversations.create(u.id, %{title: "theirs"})

      assert :ok = Admin.delete_user(admin.id, u.id)
      assert Identity.get_user(u.id).status == "deleted"
      assert Identity.user_by_link("keycloak", "sub-penta") == nil
      # the row persists (FK + audit integrity) and their conversation persists
      assert {:ok, _} = Conversations.get(u.id, c.id)
      assert Enum.any?(Audit.for_actor(admin.id), &(&1.action == "delete"))
    end

    test "a user without manage_users cannot deactivate/delete — :not_authorized" do
      mallory = user("mallory")
      u = user("penta")
      assert Admin.deactivate_user(mallory.id, u.id) == :not_authorized
      assert Admin.delete_user(mallory.id, u.id) == :not_authorized
      assert Identity.get_user(u.id).status == "active"
    end
  end
end
