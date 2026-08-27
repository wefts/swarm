defmodule Swarm.AdminTest do
  @moduledoc """
  Workspace ADR-16 step 5 + ADR-20 §6 — the admin capability boundary, kernel-owned,
  audited. `admin` (via the `admins` group): manage_access / invite_users / manage_users /
  manage_projects. `superadmin` = a live, session-bound elevation of a local Wheel member:
  + read_any_conversation / manage_wheel / manage_roles / manage_auth / manage_publicness.
  Self-escalation is closed structurally; the last Wheel member is never removed.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Admin, Audit, Conversations, Elevation, Projects}
  alias Swarm.Core.Server

  alias Swarm.Core.V1.{
    GetGroupRequest,
    ListGroupsRequest,
    ListSsoMapRequest,
    ManageGroupRequest,
    ManageSsoMapRequest
  }

  @sid "sess"

  defp user(login, overrides \\ %{}) do
    {:ok, u} =
      Identity.upsert_from_claims(
        Map.merge(
          %{provider: "keycloak", subject: "sub-#{login}", login: login, groups: []},
          overrides
        )
      )

    u
  end

  defp local_user(login) do
    {:ok, u} = Identity.invite_user(%{login: login})
    u
  end

  # A Wheel member (local; in admins too) — NOT elevated.
  defp wheel(login \\ "root#{System.unique_integer([:positive])}") do
    {:ok, u} = Identity.seed_wheel(%{id: Identity.uuid7(), login: login})
    u
  end

  # An ELEVATED actor ref for a Wheel member: {uuid, sid} with a live elevation.
  defp elevated(u) do
    proof =
      Actor.sign(
        %{
          "aud" => Actor.reauth_audience(),
          "sub" => u.login,
          "provider" => "local",
          "sid" => @sid,
          "jti" => "jti-#{System.unique_integer([:positive])}",
          "auth_time" => System.system_time(:second)
        },
        exp_in: 60
      )

    {:ok, _} = Elevation.request(%{uuid: u.id, sid: @sid}, "test", proof)
    {u.id, @sid}
  end

  defp admin_user(login) do
    u = user(login)
    :ok = Identity.add_to_group(u.id, "admins")
    u
  end

  defp assertion(login), do: Actor.sign(%{"sub" => "sub-#{login}", "provider" => "keycloak"})

  defp denied?(actor_id, action),
    do: Enum.any?(Audit.for_actor(actor_id), &(&1.action == action and &1.decision == "denied"))

  describe "roles come from groups, never per-user; groups never grant scopes" do
    test "per-user role grant/revoke and group scope grants are rejected + audited, even elevated" do
      root = elevated(wheel())
      {uuid, _} = root
      u = user("penta")
      assert {:error, :role_on_user_forbidden} = Admin.grant_role(root, u.id, "admin")
      assert {:error, :role_on_user_forbidden} = Admin.revoke_role(root, u.id, "admin")
      assert {:error, :group_scopes_forbidden} = Admin.set_group_scopes(root, "staff", ["public"])
      refute "admin" in Identity.roles_for(u.id)
      assert denied?(uuid, "grant_role") and denied?(uuid, "set_group_scopes")
    end

    test "the group set is fixed: create / rename / delete are rejected + audited" do
      root = elevated(wheel())
      assert {:error, :fixed_group_set} = Admin.create_group(root, "ops", "Ops", nil)
      assert {:error, :fixed_group_set} = Admin.rename_group(root, "staff", "Everyone")
      assert {:error, :fixed_group_set} = Admin.delete_group(root, "staff", true)
      assert Enum.map(Identity.list_groups(), & &1.id) == ["admins", "staff", "wheel"]
    end
  end

  describe "the admin boundary (ADR-20 D11)" do
    test "an admin manages admins/staff membership but cannot touch wheel" do
      admin = admin_user("adm")
      u = user("penta")
      loc = local_user("loc")

      assert :ok = Admin.grant_group(admin.id, u.id, "admins")
      assert :ok = Admin.revoke_group(admin.id, u.id, "admins")
      assert :ok = Admin.revoke_group(admin.id, u.id, "staff")
      assert Admin.grant_group(admin.id, loc.id, "wheel") == :not_authorized
      refute "wheel" in Identity.groups_for(loc.id)
      assert denied?(admin.id, "grant")
    end

    test "an elevated Wheel member manages wheel; wheel stays local-only" do
      root = elevated(wheel())
      loc = local_user("loc")
      kc = user("kc")
      assert :ok = Admin.grant_group(root, loc.id, "wheel")
      assert {:error, :wheel_local_only} = Admin.grant_group(root, kc.id, "wheel")
      assert :ok = Admin.revoke_group(root, loc.id, "wheel")
    end

    test "the LAST active local Wheel member can never be removed, deactivated or deleted" do
      w = wheel("only")
      root = elevated(w)
      assert {:error, :last_wheel_member} = Admin.revoke_group(root, w.id, "wheel")
      assert {:error, :last_wheel_member} = Admin.deactivate_user(root, w.id)
      assert {:error, :last_wheel_member} = Admin.delete_user(root, w.id)
      assert Identity.active_local_wheel_count() == 1

      # with a second member, the first may leave
      second = local_user("second")
      :ok = Admin.grant_group(root, second.id, "wheel")

      Repo.query!("UPDATE app_user SET status = 'active' WHERE id = $1", [
        Ecto.UUID.dump!(second.id)
      ])

      assert :ok = Admin.revoke_group(root, w.id, "wheel")
    end

    test "ANY lifecycle mutation of a Wheel member needs an elevation (council: gemini)" do
      admin = admin_user("adm")
      w = wheel("rootuser")
      w2 = wheel("rootuser2")
      assert Admin.deactivate_user(admin.id, w.id) == :not_authorized
      assert Admin.delete_user(admin.id, w.id) == :not_authorized
      assert Identity.get_user(w.id).status == "active"
      # an elevated Wheel member can (not the last one)
      assert :ok = Admin.deactivate_user(elevated(w2), w.id)
      assert Identity.get_user(w.id).status == "disabled"
    end

    test "role bindings and the SSO map are elevation-only; superadmin is never bindable" do
      admin = admin_user("adm")
      assert Admin.set_group_role(admin.id, "staff", "admin") == :not_authorized
      assert Admin.put_sso_map(admin.id, "keycloak", "DSI", "admins") == :not_authorized
      assert Admin.delete_sso_map(admin.id, "keycloak", "DSI") == :not_authorized
      # reads stay open to any admin cap
      assert {:ok, []} = Admin.list_sso_map(admin.id)

      root = elevated(wheel())
      assert :ok = Admin.put_sso_map(root, "keycloak", "DSI", "admins")
      assert {:error, :sso_wheel_forbidden} = Admin.put_sso_map(root, "keycloak", "root", "wheel")
      assert {:error, :unknown_group} = Admin.put_sso_map(root, "keycloak", "x", "nope")
      assert {:error, :invalid_role} = Admin.set_group_role(root, "staff", "superadmin")
      assert :ok = Admin.set_group_role(root, "staff", "admin")
      assert :ok = Admin.clear_group_role(root, "staff", "admin")
      assert Admin.set_group_role(root, "nope", "admin") == :not_found
    end

    test "an unelevated Wheel member is just an admin: no break-glass, no wheel management" do
      w = wheel()
      loc = local_user("loc")
      assert Admin.grant_group(w.id, loc.id, "wheel") == :not_authorized
      assert Admin.grant_group({w.id, "cold-session"}, loc.id, "wheel") == :not_authorized
      {:ok, c} = Conversations.create(loc.id, %{title: "theirs"})
      assert Conversations.admin_read(w.id, c.id, "peek") == :not_authorized
      assert Conversations.admin_read({w.id, @sid}, c.id, "peek") == :not_authorized
    end

    test "break-glass works ONLY under the elevated session and is audited before return" do
      w = wheel()
      loc = local_user("loc")
      {:ok, c} = Conversations.create(loc.id, %{title: "theirs"})
      root = elevated(w)
      assert {:ok, %{conversation: %{id: id}}} = Conversations.admin_read(root, c.id, "ticket")
      assert id == c.id
      # the same user's OTHER session is not elevated
      assert Conversations.admin_read({w.id, "other"}, c.id, "ticket") == :not_authorized
    end
  end

  describe "invite_users / manage_users" do
    test "an admin invites a local user or a guest, audited; a plain user cannot" do
      admin = admin_user("adm")
      assert {:ok, u} = Admin.invite_user(admin.id, %{login: "newbie", first_name: "New"})
      assert u.status == "invited" and Identity.groups_for(u.id) == ["staff"]
      assert {:ok, g} = Admin.invite_user(admin.id, %{login: "visitor", external: true})
      assert g.external and Identity.groups_for(g.id) == []
      assert Enum.any?(Audit.for_actor(admin.id), &(&1.action == "invite"))

      mallory = user("mallory")
      assert Admin.invite_user(mallory.id, %{login: "x"}) == :not_authorized
      assert Identity.by_login("x") == nil
    end

    test "deactivate/delete an ordinary user: authority dies, content stays" do
      admin = admin_user("adm")
      u = user("penta")
      :ok = Identity.add_to_group(u.id, "admins")
      {:ok, c} = Conversations.create(u.id, %{title: "theirs"})

      assert :ok = Admin.deactivate_user(admin.id, u.id)
      assert Identity.get_user(u.id).status == "disabled"
      assert Identity.roles_for(u.id) == []
      assert {:ok, _} = Conversations.get(u.id, c.id)

      assert :ok = Admin.delete_user(admin.id, u.id)
      assert Identity.get_user(u.id).status == "deleted"
      assert Identity.user_by_link("keycloak", "sub-penta") == nil

      mallory = user("mallory")
      assert Admin.deactivate_user(mallory.id, admin.id) == :not_authorized
    end
  end

  describe "reads (any admin cap; denials audited, successes not)" do
    test "roster, detail, groups, roles, sso map" do
      admin = admin_user("lister")
      _u = user("bravo")
      _u2 = user("alpha")

      assert {:ok, {users, total}} = Admin.list_users(admin.id)
      logins = Enum.map(users, & &1.login)
      assert "alpha" in logins and "bravo" in logins and total == length(users)
      assert logins == Enum.sort(logins)

      assert {:ok, {[needle], 1}} = Admin.list_users(admin.id, query: "alp")
      assert needle.login == "alpha"

      assert {:ok, view} = Admin.get_user(admin.id, admin.id)
      assert view.roles == ["admin"]
      assert Admin.get_user(admin.id, Identity.uuid7()) == :not_found

      assert {:ok, groups} = Admin.list_groups(admin.id)
      assert Enum.map(groups, & &1.id) == ["admins", "staff", "wheel"]

      assert {:ok, %{group: %{id: "staff"}, members: members}} =
               Admin.get_group(admin.id, "staff")

      assert length(members) == 3
      assert Admin.get_group(admin.id, "nope") == :not_found
      assert {:ok, roles} = Admin.list_roles(admin.id)
      assert Enum.map(roles, & &1.name) == ["user", "admin", "superadmin"]

      before = length(Audit.for_actor(admin.id))
      {:ok, _} = Admin.list_users(admin.id)
      assert length(Audit.for_actor(admin.id)) == before
    end

    test "a plain user is denied every read and each denial is audited" do
      plain = user("nobody")
      assert Admin.list_users(plain.id) == :not_authorized
      assert Admin.get_user(plain.id, plain.id) == :not_authorized
      assert Admin.list_groups(plain.id) == :not_authorized
      assert Admin.list_roles(plain.id) == :not_authorized
      assert Admin.get_group(plain.id, "staff") == :not_authorized
      assert Admin.list_sso_map(plain.id) == :not_authorized

      for action <- ~w(list_users get_user list_groups list_roles get_group list_sso_map),
          do: assert(denied?(plain.id, action), action)
    end
  end

  describe "Projects — the sole data-access container" do
    test "an admin creates a Project (becoming its owner), adds a Source and members; a plain user cannot" do
      admin = admin_user("adm")
      u = user("penta")

      assert {:ok, p} = Admin.create_project(admin.id, %{name: "Team wiki"})
      assert Projects.owner?(p.id, admin.id)
      assert {:ok, s} = Admin.add_source(admin.id, p.id, %{kind: "wiki"})
      assert :ok = Admin.add_project_member(admin.id, p.id, %{user_id: u.id})
      assert :ok = Admin.add_project_member(admin.id, p.id, %{group_id: "staff"})
      assert s.scope in Identity.scopes_for(u.id)

      assert :ok = Admin.rename_project(admin.id, p.id, "Team wiki v2")
      assert :ok = Admin.describe_project(admin.id, p.id, "the team's pages")
      assert Projects.get_project(p.id).name == "Team wiki v2"

      assert :ok = Admin.remove_project_member(admin.id, p.id, %{user_id: u.id})
      assert Admin.remove_project_member(admin.id, p.id, %{user_id: u.id}) == :not_found
      assert :ok = Admin.remove_source(admin.id, s.id)
      assert Admin.delete_project(admin.id, p.id, false) == :ok

      mallory = user("mallory")
      assert Admin.create_project(mallory.id, %{name: "x"}) == :not_authorized
      assert denied?(mallory.id, "create_project")
    end

    test "deleting a Project that owns Sources needs confirm; unknown ids are 404s" do
      admin = admin_user("adm")
      {:ok, p} = Admin.create_project(admin.id, %{name: "P"})
      {:ok, _} = Admin.add_source(admin.id, p.id, %{kind: "wiki"})
      assert Admin.delete_project(admin.id, p.id, false) == :not_confirmed
      assert Admin.delete_project(admin.id, p.id, true) == :ok
      assert Admin.delete_project(admin.id, Identity.uuid7(), true) == :not_found
      assert Admin.rename_project(admin.id, Identity.uuid7(), "x") == :not_found
      assert Admin.add_source(admin.id, Identity.uuid7(), %{kind: "wiki"}) == :not_found
      assert Admin.remove_source(admin.id, Identity.uuid7()) == :not_found

      assert Admin.add_project_member(admin.id, Identity.uuid7(), %{group_id: "staff"}) ==
               :not_found
    end

    test "SELF-GRANT guard: an admin cannot add themselves or their own group to someone else's Project" do
      admin = admin_user("adm")
      other = admin_user("other")
      {:ok, p} = Admin.create_project(other.id, %{name: "Other's"})
      {:ok, s} = Admin.add_source(other.id, p.id, %{kind: "confluence"})

      assert {:error, :self_grant} =
               Admin.add_project_member(admin.id, p.id, %{user_id: admin.id})

      # `staff` contains the admin ⇒ also a self-grant; `wheel` does not
      assert {:error, :self_grant} =
               Admin.add_project_member(admin.id, p.id, %{group_id: "staff"})

      assert :ok = Admin.add_project_member(admin.id, p.id, %{group_id: "wheel"})
      refute s.scope in Identity.scopes_for(admin.id)
      assert denied?(admin.id, "add_project_member")

      # the Project OWNER may share it with a cohort they belong to; so may an elevated actor
      assert :ok = Admin.add_project_member(other.id, p.id, %{group_id: "staff"})
      assert s.scope in Identity.scopes_for(admin.id)
      :ok = Admin.remove_project_member(other.id, p.id, %{group_id: "staff"})
      root = elevated(wheel())
      {root_id, _} = root
      assert :ok = Admin.add_project_member(root, p.id, %{user_id: root_id})
    end

    test "PUBLICNESS is elevation-only: create-as-public, set to/from public, add a Source to a public Project" do
      admin = admin_user("adm")

      assert Admin.create_project(admin.id, %{name: "Pub", visibility: "public"}) ==
               :not_authorized

      {:ok, p} = Admin.create_project(admin.id, %{name: "Shared"})
      assert Admin.set_project_visibility(admin.id, p.id, "public") == :not_authorized
      assert :ok = Admin.set_project_visibility(admin.id, p.id, "personal")

      root = elevated(wheel())
      assert :ok = Admin.set_project_visibility(root, p.id, "public")
      # now the Project is public: the admin (even as owner) cannot add a Source or flip it back
      assert Admin.add_source(admin.id, p.id, %{kind: "wiki"}) == :not_authorized
      assert Admin.set_project_visibility(admin.id, p.id, "shared") == :not_authorized
      assert Admin.delete_project(admin.id, p.id, true) == :not_authorized
      assert {:ok, s} = Admin.add_source(root, p.id, %{kind: "wiki"})
      # every authenticated actor derives it; nobody had to be a member
      assert s.scope in Identity.scopes_for(user("anyone").id)
      assert :ok = Admin.set_project_visibility(root, p.id, "shared")
      refute s.scope in Identity.scopes_for(user("anyone2").id)
    end

    test "a Project OWNER (not an admin) manages their own Project; a member only sees it" do
      admin = admin_user("adm")
      owner = user("owner")
      member = user("member")
      stranger = user("stranger")
      {:ok, p} = Admin.create_project(admin.id, %{name: "Delegated"})
      :ok = Admin.add_project_member(admin.id, p.id, %{user_id: owner.id}, role: "owner")

      assert {:ok, _} = Admin.add_source(owner.id, p.id, %{kind: "wiki"})
      assert :ok = Admin.add_project_member(owner.id, p.id, %{user_id: member.id})
      assert :ok = Admin.rename_project(owner.id, p.id, "Delegated!")
      assert Admin.set_project_visibility(owner.id, p.id, "public") == :not_authorized

      assert Admin.add_project_member(member.id, p.id, %{user_id: stranger.id}) == :not_authorized
      assert {:ok, %{project: %{id: pid}}} = Admin.get_project(member.id, p.id)
      assert pid == p.id
      assert Admin.get_project(stranger.id, p.id) == :not_found
      assert Enum.map(Admin.list_projects(member.id), & &1.id) == [p.id]
      assert Admin.list_projects(stranger.id) == []
      assert length(Admin.list_projects(admin.id)) == 1
    end
  end

  describe "over the wire (ManageGroup / SSO map / GetGroup / ListGroups)" do
    test "GROUP_CREATE / SET_SCOPES are BAD_REQUEST; SET_ROLE needs an elevation; superadmin is unbindable" do
      admin = admin_user("group-admin")
      token = assertion("group-admin")

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_CREATE,
                 group_id: "ops",
                 name: "Ops"
               },
               nil
             ).status == :CALL_BAD_REQUEST

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_SET_SCOPES,
                 group_id: "staff",
                 scopes: ["public"]
               },
               nil
             ).status == :CALL_BAD_REQUEST

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_SET_ROLE,
                 group_id: "staff",
                 role: "admin"
               },
               nil
             ).status == :CALL_NOT_AUTHORIZED

      assert Server.manage_group(
               %ManageGroupRequest{
                 assertion: token,
                 op: :GROUP_SET_ROLE,
                 group_id: "staff",
                 role: "superadmin"
               },
               nil
             ).status == :CALL_BAD_REQUEST

      listed = Server.list_groups(%ListGroupsRequest{assertion: token}, nil)
      assert listed.status == :CALL_OK
      assert Enum.map(listed.groups, & &1.id) == ["admins", "staff", "wheel"]
      refute Map.has_key?(hd(listed.groups), :granted_scopes)
      assert denied?(admin.id, "create_group")
    end

    test "GetGroup returns members (login-ordered, tombstones out); non-admins are NOT_AUTHORIZED" do
      admin = admin_user("gg-admin")
      token = assertion("gg-admin")
      _zoe = user("zoe")
      _amy = user("amy")

      resp = Server.get_group(%GetGroupRequest{assertion: token, group_id: "staff"}, nil)
      assert resp.status == :CALL_OK
      assert Enum.map(resp.members, & &1.login) == ["amy", "gg-admin", "zoe"]

      assert Server.get_group(%GetGroupRequest{assertion: token, group_id: "nope"}, nil).status ==
               :CALL_NOT_FOUND

      plain = user("plain")

      assert Server.get_group(
               %GetGroupRequest{assertion: assertion("plain"), group_id: "staff"},
               nil
             ).status ==
               :CALL_NOT_AUTHORIZED

      assert denied?(plain.id, "get_group")
      refute denied?(admin.id, "get_group")
    end

    test "ManageSsoMap over the wire: an admin is NOT_AUTHORIZED; wheel/unknown targets are BAD_REQUEST when elevated" do
      _admin = admin_user("sso-admin")
      token = assertion("sso-admin")

      put = fn t, incoming, group ->
        Server.manage_sso_map(
          %ManageSsoMapRequest{
            assertion: t,
            op: :SSO_MAP_PUT,
            provider: "keycloak",
            incoming_group: incoming,
            our_group_id: group
          },
          nil
        )
      end

      assert put.(token, "DSI", "admins").status == :CALL_NOT_AUTHORIZED
      assert Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil).status == :CALL_OK

      w = wheel("rootsso")
      _ = elevated(w)
      root_t = Actor.sign(%{"sub" => "rootsso", "provider" => "local", "sid" => @sid})
      assert put.(root_t, "DSI", "admins").status == :CALL_OK
      assert put.(root_t, "root", "wheel").status == :CALL_BAD_REQUEST
      assert put.(root_t, "x", "nope").status == :CALL_BAD_REQUEST
      assert put.(root_t, "", "admins").status == :CALL_BAD_REQUEST

      listed = Server.list_sso_map(%ListSsoMapRequest{assertion: token}, nil)

      assert Enum.map(listed.mappings, &{&1.incoming_group, &1.our_group_id}) == [
               {"DSI", "admins"}
             ]

      # the same Wheel member from a COLD session is not elevated
      cold_t = Actor.sign(%{"sub" => "rootsso", "provider" => "local", "sid" => "cold"})
      assert put.(cold_t, "Other", "staff").status == :CALL_NOT_AUTHORIZED
    end
  end
end
