defmodule Swarm.Graph.TraverseRelaxationTest do
  @moduledoc """
  swarm ADR-3 — the node-bounded relaxation replacing path enumeration. Proves it
  computes the same max-product confidence as brute-force path enumeration, that
  confidence and depth are independent aggregates (max-conf may be at a later depth
  while reported depth stays min-hops), and that the edge budget truncates
  best-effort.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Traverse
  alias Swarm.Repo

  defp n, do: add_node!(%{type: "concept", scope: "public"})

  defp edge(a, b, rel, prov) do
    {:ok, _} = Graph.add_edge(a, b, "rel", prov, reliability: rel, scope: "public")
  end

  # Brute-force max-product per node over all walks of ≤ max_depth edges, using the
  # SAME decayed factors the relaxation sees (so the test isolates the algorithm,
  # not the decay arithmetic).
  defp brute(start, max_depth) do
    lambda = Swarm.Config.decay_lambda()

    %{rows: rows} =
      Repo.query!(
        "SELECT src, dst, reliability * exp(-$1::float8 * EXTRACT(EPOCH FROM (now() - last_seen)) / 86400.0) " <>
          "FROM edge WHERE reward >= 0",
        [lambda]
      )

    adj = Enum.group_by(rows, fn [s, _, _] -> s end, fn [_, d, f] -> {d, f} end)
    brute_walk(adj, start, 1.0, 0, max_depth, %{})
  end

  defp brute_walk(_adj, _node, _prod, depth, max_depth, acc) when depth >= max_depth, do: acc

  defp brute_walk(adj, node, prod, depth, max_depth, acc) do
    Enum.reduce(Map.get(adj, node, []), acc, fn {dst, f}, acc ->
      np = prod * f
      acc = Map.update(acc, dst, np, &max(&1, np))
      brute_walk(adj, dst, np, depth + 1, max_depth, acc)
    end)
  end

  test "confidence = max-product; reported depth = min-hops (independent aggregates)" do
    a = n()
    b = n()
    c = n()
    # a→b is a weak 1-hop (0.1); a→c→b is a stronger 2-hop (0.9·0.9 = 0.81).
    edge(a, b, 0.1, "p1")
    edge(a, c, 0.9, "p2")
    edge(c, b, 0.9, "p3")

    hits = Map.new(Traverse.traverse(a, 3), &{&1.id, &1})

    # max-product wins even though it is the longer path…
    assert_in_delta hits[b].confidence, 0.81, 0.01
    # …but depth stays the minimum hop-distance (the direct a→b), independent of it.
    assert hits[b].depth == 1
    assert hits[c].depth == 1
  end

  test "matches brute-force path enumeration on random small graphs (equivalence)" do
    :rand.seed(:exsss, {7, 11, 13})

    for _trial <- 1..20 do
      truncate_graph()
      nodes = for _ <- 1..6, do: n()
      # ~10 random directed edges with random reliabilities
      for _ <- 1..10 do
        a = Enum.random(nodes)
        b = Enum.random(nodes)

        if a != b,
          do:
            edge(
              a,
              b,
              Float.round(0.1 + :rand.uniform() * 0.85, 3),
              "p#{:rand.uniform(1_000_000)}"
            )
      end

      start = hd(nodes)
      max_depth = 4
      # brute-force may re-reach `start` via a cycle; `traverse` excludes the start
      # by contract, so drop it from the expected set before comparing.
      expected = brute(start, max_depth) |> Map.delete(start)
      got = Map.new(Traverse.traverse(start, max_depth), &{&1.id, &1.confidence})

      assert Map.keys(got) |> Enum.sort() == Map.keys(expected) |> Enum.sort()

      Enum.each(expected, fn {id, conf} ->
        assert_in_delta got[id], conf, 1.0e-9
      end)
    end
  end

  test "the edge-visit budget truncates best-effort (ADR-3)" do
    a = n()
    bs = for _ <- 1..5, do: n()
    for {b, i} <- Enum.with_index(bs), do: edge(a, b, 0.5, "p#{i}")

    # budget 1 < the 5 outgoing edges → halt after the first level, flagged truncated
    full = Traverse.walk(a, 3, edge_budget: 1_000)
    refute full.truncated

    capped = Traverse.walk(a, 3, edge_budget: 1)
    assert capped.truncated
  end

  test "traverse/3 returns just the hits; walk/3 adds the truncated flag" do
    a = n()
    b = n()
    edge(a, b, 0.7, "p1")

    assert [%{id: ^b, confidence: _, depth: 1}] = Traverse.traverse(a, 2)
    assert %{hits: [%{id: ^b}], truncated: false} = Traverse.walk(a, 2)
  end
end
