defmodule Swarm.AdminTest do
  @moduledoc """
  Workspace ADR-16 step 5 — access grants + user management, kernel-owned,
  admin-mutable, audited. Capabilities (derived from role_grant, default-deny):
  admin = {manage_access, invite_users, manage_users}; superadmin = all +
  read_any_conversation. Role grants are privilege management → superadmin-only.
  admin does NOT get chat-read (step 4) nor another user's own KB.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Admin, Audit, Conversations}

  defp user(login) do
    {:ok, u} =
      Identity.upsert_from_claims(%{
        provider: "keycloak",
        subject: "sub-#{login}",
        login: login,
        groups: []
      })

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

  defp admin_user(login) do
    u = user(login)
    :ok = Admin.grant_role(superadmin(), u.id, "admin")
    u
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

      assert {:ok, users} = Admin.list_users(admin.id)
      logins = Enum.map(users, & &1.login)
      assert "alpha" in logins and "bravo" in logins
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

      assert Enum.any?(
               Audit.for_actor(plain.id),
               &(&1.action == "list_users" and &1.decision == "denied")
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

      assert {:ok, users} = Admin.list_users(root)
      refute Enum.any?(users, &(&1.login == "ghost"))

      assert {:ok, all} = Admin.list_users(root, include_deleted: true)
      g = Enum.find(all, &(&1.login == "ghost"))
      assert g && g.status == "deleted"
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
