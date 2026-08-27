defmodule Swarm.Scope.ProjectReadSurfacesTest do
  @moduledoc """
  ADR-20 §11 — the read surfaces re-proved under PROJECT-DERIVED scopes, on the real RPC
  path (a signed assertion ⇒ `Identity.scopes_for` ⇒ the gate): search, KbSearch,
  Neighborhood, ActivityFeed. Positive controls throughout: a member sees their
  Project's rows, a member of another Project / a guest sees none — and wire scopes are inert.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Core, Projects}
  alias Swarm.Core.Server
  alias Swarm.Core.V1.{ActivityFeedRequest, NeighborhoodRequest, SearchRequest}
  alias Swarm.Graph.Store

  setup do
    Swarm.GraphCase.truncate_graph()

    {:ok, a} = Projects.create_project(%{name: "Team A"})
    {:ok, sa} = Projects.add_source(a.id, %{kind: "confluence"})
    {:ok, b} = Projects.create_project(%{name: "Team B"})
    {:ok, sb} = Projects.add_source(b.id, %{kind: "confluence"})

    alice = user("alice")
    bob = user("bob")
    {:ok, guest} = Identity.invite_user(%{login: "visitor", external: true})

    Repo.query!("UPDATE app_user SET status = 'active' WHERE id = $1", [Ecto.UUID.dump!(guest.id)])

    :ok = Projects.add_member(a.id, %{user_id: alice.id})
    :ok = Projects.add_member(b.id, %{user_id: bob.id})

    a_center = Store.upsert_node("article", "NEEDLEALPHA hub", scope: sa.scope)
    a_leaf = Store.upsert_node("concept", "NEEDLEALPHA leaf", scope: sa.scope)
    {:ok, _} = Store.add_edge(a_center, a_leaf, "mentions", "ev-a", scope: sa.scope)
    b_center = Store.upsert_node("article", "NEEDLEBRAVO hub", scope: sb.scope)

    %{
      alice: alice,
      bob: bob,
      guest: guest,
      sa: sa.scope,
      sb: sb.scope,
      a_center: a_center,
      b_center: b_center
    }
  end

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

  defp assertion(login), do: Actor.sign(%{"sub" => "sub-#{login}", "provider" => "keycloak"})
  defp local_assertion(login), do: Actor.sign(%{"sub" => login, "provider" => "local"})

  test "Core.search + KbSearch: derived scopes decide; wire scopes are inert", ctx do
    assert Core.search("NEEDLEALPHA", Identity.scopes_for(ctx.alice.id), limit: 10) |> length() ==
             2

    assert Core.search("NEEDLEALPHA", Identity.scopes_for(ctx.bob.id), limit: 10) == []
    assert Core.search("NEEDLEBRAVO", Identity.scopes_for(ctx.guest.id), limit: 10) == []

    # bob CLAIMS Team A's scope on the wire — derivation wins, he sees nothing of A
    spoof =
      Server.kb_search(
        %SearchRequest{query: "NEEDLEALPHA", assertion: assertion("bob"), scopes: [ctx.sa]},
        nil
      )

    assert spoof.hits == []

    own =
      Server.kb_search(
        %SearchRequest{query: "NEEDLEALPHA", assertion: assertion("alice"), scopes: []},
        nil
      )

    assert Enum.map(own.hits, & &1.key) |> Enum.sort() == ["NEEDLEALPHA hub", "NEEDLEALPHA leaf"]
  end

  test "Neighborhood: a member centers on their Project's node; another member / a guest get NOT_FOUND",
       ctx do
    found =
      Server.neighborhood(
        %NeighborhoodRequest{node_id: ctx.a_center, scopes: [], viewer: assertion("alice")},
        nil
      )

    assert found.status == :FOUND
    assert Enum.map(found.nodes, & &1.key) == ["NEEDLEALPHA leaf"]

    for viewer <- [assertion("bob"), local_assertion("visitor")] do
      resp =
        Server.neighborhood(
          %NeighborhoodRequest{node_id: ctx.a_center, scopes: [ctx.sa], viewer: viewer},
          nil
        )

      assert resp.status == :NOT_FOUND
    end
  end

  test "ActivityFeed: a member sees their Project's events, a stranger sees none", ctx do
    own = Server.activity_feed(%ActivityFeedRequest{scopes: [], viewer: assertion("alice")}, nil)
    assert own.status == :FOUND

    # direct Store writes emit only the edge event (ingest emits node_added); it is Team A's
    assert Enum.map(own.events, & &1.kind) == ["edge_reinforced"]

    # Team A's event never reaches bob even when he CLAIMS the scope (wire scopes inert)
    bobs =
      Server.activity_feed(%ActivityFeedRequest{scopes: [ctx.sa], viewer: assertion("bob")}, nil)

    assert bobs.events == []

    none =
      Server.activity_feed(
        %ActivityFeedRequest{scopes: [ctx.sa], viewer: local_assertion("visitor")},
        nil
      )

    assert none.status == :not_found or none.events == []
  end
end
