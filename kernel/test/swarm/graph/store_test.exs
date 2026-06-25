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
      assert {:error, %Ecto.Changeset{}} = Graph.add_node(%{type: "concept", reliability: 1.5})
      assert {:error, %Ecto.Changeset{}} = Graph.add_node(%{reliability: 0.5})
    end
  end

  describe "add_edge/5 — insert-or-increment + provenance guard (ADR-9)" do
    setup do
      %{a: add_node!(%{type: "concept"}), b: add_node!(%{type: "article"})}
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

  describe "add_edge/5 — distinct-origin reinforcement (workspace ADR-13)" do
    setup do
      %{a: add_node!(%{type: "concept"}), b: add_node!(%{type: "article"})}
    end

    test "a fresh event of an ALREADY-COUNTED origin does NOT reinforce", %{a: a, b: b} do
      # Two distinct emission events (different provenance) but ONE evidential
      # origin — N derivatives of one source must not corroborate as independent.
      {:ok, first} = Graph.add_edge(a, b, "mentions", "ev-1", origin: "src-A")

      assert {:ok, %{seen_count: 1, reinforced: false}} =
               Graph.add_edge(a, b, "mentions", "ev-2", origin: "src-A")

      assert first.seen_count == 1
    end

    test "distinct origins DO reinforce (corroboration grows)", %{a: a, b: b} do
      {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-1", origin: "src-A")

      assert {:ok, %{seen_count: 2, reinforced: true}} =
               Graph.add_edge(a, b, "mentions", "ev-2", origin: "src-B")
    end

    test "absent :origin defaults to provenance (pre-v4 behaviour preserved)", %{a: a, b: b} do
      # Without an explicit origin, every distinct event is its own origin, so
      # two distinct provenance keys still reinforce exactly as before.
      {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-1")

      assert {:ok, %{seen_count: 2, reinforced: true}} =
               Graph.add_edge(a, b, "mentions", "ev-2")
    end

    test "re-detecting the same emission instance is still a no-op", %{a: a, b: b} do
      {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-1", origin: "src-A")

      assert {:ok, %{seen_count: 1, reinforced: false}} =
               Graph.add_edge(a, b, "mentions", "ev-1", origin: "src-A")
    end

    test "seen_count equals the number of distinct origins on the edge", %{a: a, b: b} do
      {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-1", origin: "src-A")
      {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-2", origin: "src-A")
      {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-3", origin: "src-B")
      {:ok, last} = Graph.add_edge(a, b, "mentions", "ev-4", origin: "src-C")

      # 4 events, 3 distinct origins (A, B, C) → seen_count 3.
      assert last.seen_count == 3
    end
  end
end
