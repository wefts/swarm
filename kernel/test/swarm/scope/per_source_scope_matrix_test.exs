defmodule Swarm.Scope.PerSourceScopeMatrixTest do
  @moduledoc """
  ADR-18 per-source scope ship gate, re-proved under ADR-20 project-derived scopes.

  Proves source-scope derivation and read visibility with positive controls: a persona sees
  exactly the source scopes of the Projects it is a member of plus public, and no ungranted
  source scope leaks through the graph or activity feed.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Activity, Graph, Projects}
  alias Swarm.Graph.Store

  setup do
    Swarm.GraphCase.truncate_graph()
    :ok
  end

  defp claims(login) do
    %{
      provider: "keycloak",
      subject: "sub-#{login}",
      login: login,
      emails: [%{email: "#{login}@example.test", verified: true, primary: true}],
      groups: []
    }
  end

  defp source!(project_name, kind) do
    {:ok, p} = Projects.create_project(%{name: project_name})
    {:ok, s} = Projects.add_source(p.id, %{kind: kind})
    {p, s.scope}
  end

  defp visible_node_keys(scopes) do
    %{rows: rows} =
      Repo.query!("SELECT key FROM node WHERE scope = ANY($1::text[]) ORDER BY key", [scopes])

    List.flatten(rows)
  end

  defp activity_summary(page), do: Enum.map(page.events, &{&1.kind, &1.subject_type})

  describe "per-source scope matrix" do
    test "a user sees exactly the source scopes of their Projects plus public" do
      {internal, wiki} = source!("Internal", "wiki")
      {:ok, ldap_src} = Projects.add_source(internal.id, %{kind: "ldap"})
      ldap = ldap_src.scope
      {_ops, confluence} = source!("Operations", "confluence")
      {_ops2, iac} = source!("Operations 2", "iac")

      Store.upsert_node("article", "matrix-wiki", scope: wiki)
      Store.upsert_node("article", "matrix-ldap", scope: ldap)
      Store.upsert_node("article", "matrix-confluence", scope: confluence)
      Store.upsert_node("article", "matrix-iac", scope: iac)
      Store.upsert_node("article", "matrix-public", scope: "public")

      {:ok, member} = Identity.upsert_from_claims(claims("member-user"))
      {:ok, nobody} = Identity.upsert_from_claims(claims("nobody-user"))
      # a direct membership in the Internal Project — NOT the cohort, so this test proves
      # per-membership isolation (a non-member sees only public)
      :ok = Projects.add_member(internal.id, %{user_id: member.id})

      assert Identity.scopes_for(nobody.id) == ["public"]

      member_scopes = Identity.scopes_for(member.id)
      assert Enum.sort(member_scopes) == Enum.sort(["public", ldap, wiki])

      assert visible_node_keys(member_scopes) == ["matrix-ldap", "matrix-public", "matrix-wiki"]
      assert visible_node_keys(Identity.scopes_for(nobody.id)) == ["matrix-public"]
    end
  end

  describe "activity predicate audit" do
    test "source-scoped activity does not surface edges or endpoints to another source scope" do
      {_p, wiki} = source!("Internal", "wiki")
      {_q, ldap} = source!("Directory", "ldap")

      wiki_a = Swarm.GraphCase.add_node!(%{type: "article", key: "activity-wiki-a", scope: wiki})
      wiki_b = Swarm.GraphCase.add_node!(%{type: "concept", key: "activity-wiki-b", scope: wiki})

      {:ok, _} =
        Graph.add_edge(wiki_a, wiki_b, "mentions", "activity-wiki-edge",
          reliability: 0.9,
          scope: wiki
        )

      ldap_page = Activity.feed(scopes: [ldap])
      assert ldap_page.status == :not_found
      assert ldap_page.events == []

      wiki_page = Activity.feed(scopes: [wiki])
      assert wiki_page.status == :found

      assert activity_summary(wiki_page) == [
               {"node_added", "article"},
               {"node_added", "concept"},
               {"edge_reinforced", ""}
             ]
    end
  end
end
