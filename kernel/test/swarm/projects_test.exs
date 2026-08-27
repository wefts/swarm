defmodule Swarm.ProjectsTest do
  @moduledoc """
  Workspace ADR-20 — Projects are the SOLE data-access container. Effective source scopes
  derive from Project membership (a user, or a group the user is in) plus public Projects;
  groups confer no visibility; a guest / non-member derives exactly `["public"]`; two
  same-kind Sources in two Projects can never collide on one scope.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Core, Projects}
  alias Swarm.Graph.Store

  setup do
    Swarm.GraphCase.truncate_graph()
    :ok
  end

  defp user(login, groups \\ []) do
    {:ok, u} =
      Identity.upsert_from_claims(%{
        provider: "keycloak",
        subject: "sub-#{login}",
        login: login,
        groups: groups
      })

    u
  end

  defp guest(login) do
    {:ok, g} = Identity.invite_user(%{login: login, external: true})
    g
  end

  defp project!(name, opts \\ []) do
    {:ok, p} =
      Projects.create_project(%{name: name, visibility: Keyword.get(opts, :visibility, "shared")})

    {:ok, s} = Projects.add_source(p.id, %{kind: Keyword.get(opts, :kind, "wiki")})
    {p, s}
  end

  defp visible_keys(scopes) do
    Repo.query!("SELECT key FROM node WHERE scope = ANY($1::text[]) ORDER BY key", [scopes]).rows
    |> List.flatten()
  end

  describe "effective scopes derive from Project membership — and from nothing else" do
    test "a direct user member derives the Project's source scopes; a non-member does not" do
      {p, s} = project!("Internal")
      alice = user("alice")
      bob = user("bob")
      :ok = Projects.add_member(p.id, %{user_id: alice.id})

      assert Identity.scopes_for(alice.id) == ["public", s.scope]
      assert Identity.scopes_for(bob.id) == ["public"]
      assert Projects.member?(p.id, alice.id)
      refute Projects.member?(p.id, bob.id)
    end

    test "a group member derives through the group; leaving the group removes it" do
      {p, s} = project!("Internal")
      :ok = Projects.add_member(p.id, %{group_id: "staff"})
      # every non-guest joins the default cohort (staff) at provisioning
      alice = user("alice")
      assert "staff" in Identity.groups_for(alice.id)
      assert Identity.scopes_for(alice.id) == ["public", s.scope]

      :ok = Identity.remove_from_group(alice.id, "staff")
      assert Identity.scopes_for(alice.id) == ["public"]
    end

    test "a GUEST never joins the default cohort and sees only public (+ explicit membership)" do
      {p, s} = project!("Internal")
      :ok = Projects.add_member(p.id, %{group_id: "staff"})
      g = guest("visitor")

      assert g.external
      assert Identity.groups_for(g.id) == []
      assert Identity.scopes_for(g.id) == ["public"]

      {q, qs} = project!("Guest project", kind: "confluence")
      :ok = Projects.add_member(q.id, %{user_id: g.id})
      assert Identity.scopes_for(g.id) == ["public", qs.scope]
      refute s.scope in Identity.scopes_for(g.id)
    end

    test "Admins and Wheel confer NO visibility by themselves (roles ≠ scopes, ADR-20 D8)" do
      {_p, s} = project!("Operations", kind: "iac")
      admin = user("adm")
      :ok = Identity.add_to_group(admin.id, "admins")
      {:ok, root} = Identity.seed_wheel(%{id: Identity.uuid7(), login: "rootuser"})

      assert "admin" in Identity.roles_for(admin.id)
      refute s.scope in Identity.scopes_for(admin.id)
      assert "wheel" in Identity.groups_for(root.id)
      refute s.scope in Identity.scopes_for(root.id)
    end

    test "a public Project is derived by EVERY authenticated actor, never by anonymous; flipping it back removes it" do
      {p, s} = project!("Public wiki", visibility: "public")
      alice = user("alice")
      g = guest("visitor")

      assert s.scope in Identity.scopes_for(alice.id)
      assert s.scope in Identity.scopes_for(g.id)
      assert Projects.effective_scopes(nil) == []

      :ok = Projects.set_visibility(p.id, "shared")
      refute s.scope in Identity.scopes_for(alice.id)
      refute s.scope in Identity.scopes_for(g.id)
    end

    test "removing the membership, the Source, or the Project makes the rows unreachable (fail-closed)" do
      {p, s} = project!("Internal")
      alice = user("alice")
      :ok = Projects.add_member(p.id, %{user_id: alice.id})
      Store.upsert_node("article", "internal-page", scope: s.scope)

      assert visible_keys(Identity.scopes_for(alice.id)) == ["internal-page"]

      :ok = Projects.remove_member(p.id, %{user_id: alice.id})
      assert visible_keys(Identity.scopes_for(alice.id)) == []

      :ok = Projects.add_member(p.id, %{user_id: alice.id})
      :ok = Projects.delete_project(p.id)
      assert Identity.scopes_for(alice.id) == ["public"]
      # the row keeps its coordinate — nobody can derive it any more
      assert Repo.query!("SELECT scope FROM node WHERE key = 'internal-page'").rows == [[s.scope]]
    end
  end

  describe "the src:<name> collision regression (ADR-20 D2)" do
    test "two same-kind Sources in two Projects have distinct scopes and no cross-visibility" do
      {a, sa} = project!("Team A", kind: "confluence")
      {b, sb} = project!("Team B", kind: "confluence")
      refute sa.scope == sb.scope
      assert sa.kind == sb.kind and sa.label == sb.label

      alice = user("alice")
      bob = user("bob")
      :ok = Projects.add_member(a.id, %{user_id: alice.id})
      :ok = Projects.add_member(b.id, %{user_id: bob.id})

      Store.upsert_node("article", "NEEDLEALPHA page", scope: sa.scope)
      Store.upsert_node("article", "NEEDLEBRAVO page", scope: sb.scope)

      assert visible_keys(Identity.scopes_for(alice.id)) == ["NEEDLEALPHA page"]
      assert visible_keys(Identity.scopes_for(bob.id)) == ["NEEDLEBRAVO page"]

      # and through the real read path
      assert Core.search("NEEDLEBRAVO", Identity.scopes_for(alice.id), limit: 10) == []
      assert Core.search("NEEDLEALPHA", Identity.scopes_for(alice.id), limit: 10) |> length() == 1
    end

    test "a human label can never be a graph scope" do
      assert_raise Swarm.Graph.ContractError, fn ->
        Store.upsert_node("article", "label-scoped", scope: "src:confluence")
      end

      assert_raise Swarm.Graph.ContractError, fn ->
        Store.upsert_node("article", "group-scoped", scope: "group")
      end
    end
  end

  describe "the registry" do
    test "scope!/1, registered_scope?/1 and scope_by_kind!/1 (0 | 1 | many)" do
      {_p, s} = project!("Internal", kind: "ldap")
      assert Projects.scope!(s.id) == s.scope
      assert Projects.registered_scope?(s.scope)
      refute Projects.registered_scope?("src:0192aaaa-bbbb-7ccc-8ddd-eeeeffff0000")
      refute Projects.registered_scope?("src:ldap")
      refute Projects.registered_scope?("public")

      assert Projects.scope_by_kind!("ldap") == s.scope
      assert_raise ArgumentError, ~r/no source of kind/, fn -> Projects.scope_by_kind!("iac") end

      {_q, _s2} = project!("Other directory", kind: "ldap")
      assert_raise ArgumentError, ~r/pass a source id/, fn -> Projects.scope_by_kind!("ldap") end
      assert_raise ArgumentError, fn -> Projects.scope!(Identity.uuid7()) end
    end

    test "validation: blank name, bad visibility, bad kind, unknown project/group/user" do
      assert Projects.create_project(%{name: "  "}) == {:error, :invalid_name}

      assert Projects.create_project(%{name: "x", visibility: "secret"}) ==
               {:error, :invalid_visibility}

      {:ok, p} = Projects.create_project(%{name: "P"})
      assert Projects.add_source(p.id, %{kind: "Bad Kind"}) == {:error, :invalid_kind}
      assert Projects.add_source(Identity.uuid7(), %{kind: "wiki"}) == {:error, :not_found}
      assert Projects.add_member(p.id, %{group_id: "nope"}) == {:error, :unknown_group}
      assert Projects.add_member(p.id, %{user_id: Identity.uuid7()}) == {:error, :unknown_user}
      assert Projects.add_member(p.id, %{user_id: "not-a-uuid"}) == {:error, :unknown_user}
      assert Projects.add_member(p.id, %{}) == {:error, :invalid_member}
      assert Projects.set_visibility(p.id, "loud") == {:error, :invalid_visibility}
      assert Projects.get_project("garbage") == nil
      assert Projects.delete_project(Identity.uuid7()) == {:error, :not_found}
    end

    test "a group can never hold the owner role (owners are people)" do
      {:ok, p} = Projects.create_project(%{name: "P"})

      assert Projects.add_member(p.id, %{group_id: "staff"}, role: "owner") ==
               {:error, :invalid_member}

      assert :ok = Projects.add_member(p.id, %{group_id: "staff"}, role: "member")
      refute Projects.owner?(p.id, user("alice").id)
    end

    test "a deactivated account derives nothing — not even public Projects (belt)" do
      {_p, s} = project!("Handbook", visibility: "public")
      u = user("alice")
      assert s.scope in Projects.effective_scopes(u.id)
      :ok = Identity.deactivate_user(u.id)
      assert Projects.effective_scopes(u.id) == []
    end

    test "creator becomes the owner; members list owners first; project_view aggregates" do
      alice = user("alice")
      {:ok, p} = Projects.create_project(%{name: "Alice's", created_by: alice.id})
      assert Projects.owner?(p.id, alice.id)
      :ok = Projects.add_member(p.id, %{group_id: "staff"})
      {:ok, _} = Projects.add_source(p.id, %{kind: "wiki", label: "Team wiki"})

      %{project: proj, sources: [src], members: members} = Projects.project_view(p.id)
      assert proj.name == "Alice's"
      assert src.label == "Team wiki" and src.kind == "wiki" and src.origin == "admin"
      assert [%{role: "owner", login: "alice"}, %{group_id: "staff", name: "Staff"}] = members
      assert Enum.map(Projects.list_projects_for(alice.id), & &1.id) == [p.id]
    end
  end
end
