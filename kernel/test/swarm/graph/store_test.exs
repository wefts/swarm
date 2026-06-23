defmodule Swarm.Graph.StoreTest do
  use Swarm.GraphCase, async: false

  describe "add_node/1" do
    test "inserts with defaults (scope private, fence 0)" do
      assert {:ok, node} = Graph.add_node(%{type: "concept"})
      assert node.type == "concept"
      assert node.scope == "private"
      assert node.fence == 0
    end

    test "accepts a stored embedding vector of the configured dimension" do
      dim = Swarm.Config.embedding_dim()
      assert {:ok, node} = Graph.add_node(%{type: "file", vec: List.duplicate(0.0, dim)})
      assert node.id
    end

    test "fails loud on out-of-range reliability and missing type" do
      assert {:error, %Ecto.Changeset{}} = Graph.add_node(%{type: "x", reliability: 1.5})
      assert {:error, %Ecto.Changeset{}} = Graph.add_node(%{reliability: 0.5})
    end
  end

  describe "add_edge/5 — insert-or-increment + provenance guard (ADR-9)" do
    setup do
      %{a: add_node!(%{type: "a"}), b: add_node!(%{type: "b"})}
    end

    test "first detection inserts and counts once", %{a: a, b: b} do
      assert {:ok, %{seen_count: 1, reinforced: true}} =
               Graph.add_edge(a, b, "mentions", "event-1")
    end

    test "re-detecting the SAME provenance event does not reinforce", %{a: a, b: b} do
      {:ok, first} = Graph.add_edge(a, b, "mentions", "event-1")
      {:ok, again} = Graph.add_edge(a, b, "mentions", "event-1")

      assert again.id == first.id
      assert again.reinforced == false
      assert again.seen_count == 1
    end

    test "a provenance-distinct event reinforces (seen_count grows)", %{a: a, b: b} do
      {:ok, _} = Graph.add_edge(a, b, "mentions", "event-1")

      assert {:ok, %{seen_count: 2, reinforced: true}} =
               Graph.add_edge(a, b, "mentions", "event-2")
    end

    test "a different visibility scope is a different edge (natural key)" do
      # Public endpoints so both scopes satisfy the ADR-4 visibility invariant
      # (a private and a public edge are each ≤ the endpoints).
      p = add_node!(%{type: "file", scope: "public"})
      q = add_node!(%{type: "concept", scope: "public"})
      {:ok, private} = Graph.add_edge(p, q, "mentions", "event-1", scope: "private")
      {:ok, public} = Graph.add_edge(p, q, "mentions", "event-1", scope: "public")

      assert private.id != public.id
      assert public.seen_count == 1
    end
  end
end
