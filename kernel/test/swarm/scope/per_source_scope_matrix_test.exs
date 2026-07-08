defmodule Swarm.Scope.PerSourceScopeMatrixTest do
  @moduledoc """
  ADR-18 per-source scope ship gate.

  Proves source-scope derivation and read visibility with positive controls:
  a persona sees exactly its granted source scopes plus public, and no ungranted
  source scope leaks through the graph or activity feed.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Activity, Graph}
  alias Swarm.Graph.Store

  setup do
    Swarm.GraphCase.truncate_graph()
    :ok
  end

  defp claims(login, groups) do
    %{
      provider: "keycloak",
      subject: "sub-#{login}",
      login: login,
      emails: [%{email: "#{login}@example.test", verified: true, primary: true}],
      groups: groups
    }
  end

  defp visible_node_keys(scopes) do
    %{rows: rows} =
      Repo.query!(
        "SELECT key FROM node WHERE scope = ANY($1::text[]) ORDER BY key",
        [scopes]
      )

    List.flatten(rows)
  end

  defp activity_summary(page) do
    Enum.map(page.events, &{&1.kind, &1.subject_type})
  end

  describe "per-source scope matrix" do
    test "a user sees exactly its granted source scopes plus public" do
      Store.upsert_node("article", "matrix-wiki", scope: "src:wiki")
      Store.upsert_node("article", "matrix-ldap", scope: "src:ldap")
      Store.upsert_node("article", "matrix-confluence", scope: "src:confluence")
      Store.upsert_node("article", "matrix-iac", scope: "src:iac")
      Store.upsert_node("article", "matrix-public", scope: "public")

      {:ok, everyone_user} = Identity.upsert_from_claims(claims("everyone-user", []))
      {:ok, nobody_user} = Identity.upsert_from_claims(claims("nobody-user", []))

      :ok = Identity.put_group_scopes("everyone", ["src:wiki", "src:ldap"])
      :ok = Identity.add_to_group(everyone_user.id, "everyone")

      assert Identity.scopes_for(nobody_user.id) == ["public"]

      everyone_scopes = Identity.scopes_for(everyone_user.id)
      assert Enum.sort(everyone_scopes) == ["public", "src:ldap", "src:wiki"]

      assert visible_node_keys(everyone_scopes) == [
               "matrix-ldap",
               "matrix-public",
               "matrix-wiki"
             ]

      assert visible_node_keys(Identity.scopes_for(nobody_user.id)) == ["matrix-public"]
    end
  end

  describe "activity predicate audit" do
    test "source-scoped activity does not surface edges or endpoints to another source scope" do
      wiki_a =
        Swarm.GraphCase.add_node!(%{
          type: "article",
          key: "activity-wiki-a",
          scope: "src:wiki"
        })

      wiki_b =
        Swarm.GraphCase.add_node!(%{
          type: "concept",
          key: "activity-wiki-b",
          scope: "src:wiki"
        })

      {:ok, _} =
        Graph.add_edge(wiki_a, wiki_b, "mentions", "activity-wiki-edge",
          reliability: 0.9,
          scope: "src:wiki"
        )

      ldap_page = Activity.feed(scopes: ["src:ldap"])
      assert ldap_page.status == :not_found
      assert ldap_page.events == []

      wiki_page = Activity.feed(scopes: ["src:wiki"])
      assert wiki_page.status == :found

      assert activity_summary(wiki_page) == [
               {"node_added", "article"},
               {"node_added", "concept"},
               {"edge_reinforced", ""}
             ]
    end
  end
end
