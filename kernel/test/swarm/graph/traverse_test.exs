defmodule Swarm.Graph.TraverseTest do
  use Swarm.GraphCase, async: false

  # Fixture: a -0.5-> b -0.5-> c, plus a stronger direct a -0.9-> c.
  # last_seen defaults to now(), so decay ≈ 1 and confidence ≈ product of
  # reliabilities; the per-node max keeps the strongest path (ADR-3).
  setup do
    a = add_node!(%{type: "concept", scope: "public"})
    b = add_node!(%{type: "article", scope: "public"})
    c = add_node!(%{type: "file", scope: "private"})

    # Edge scope = narrowest endpoint (as ingest sets it): a→b public, the rest
    # touch private c. Visibility (Task 06) now prunes on edge scope too.
    {:ok, _} = Graph.add_edge(a, b, "rel", "e1", reliability: 0.5, scope: "public")
    {:ok, _} = Graph.add_edge(b, c, "rel", "e2", reliability: 0.5, scope: "private")
    {:ok, _} = Graph.add_edge(a, c, "rel", "e3", reliability: 0.9, scope: "private")

    %{a: a, b: b, c: c}
  end

  test "reaches nodes with best-path confidence, strongest path wins", %{a: a, b: b, c: c} do
    hits = Map.new(Graph.traverse(a, 3), &{&1.id, &1})

    assert Map.keys(hits) |> Enum.sort() == Enum.sort([b, c])
    assert_in_delta hits[b].confidence, 0.5, 0.01
    # direct 0.9 beats the 0.5*0.5 = 0.25 two-hop path
    assert_in_delta hits[c].confidence, 0.9, 0.01
    assert hits[c].depth == 1
  end

  test "scope filter prunes at the index (ADR-5 mechanism)", %{a: a, b: b} do
    hits = Graph.traverse(a, 3, scopes: ["public"])
    # c is private → both edges into it are pruned; only public b remains
    assert Enum.map(hits, & &1.id) == [b]
  end

  test "cycles terminate and do not loop", %{a: a, b: b} do
    {:ok, _} = Graph.add_edge(b, a, "rel", "e4", reliability: 0.9)

    hits = Graph.traverse(a, 5)
    # terminates; b is reached, the cycle back to a is pruned (not re-expanded)
    assert b in Enum.map(hits, & &1.id)
  end
end
