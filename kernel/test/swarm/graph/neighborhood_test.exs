defmodule Swarm.Graph.NeighborhoodTest do
  @moduledoc """
  ADR-15 — the bounded, scope-enforced neighborhood projection. Center visibility
  gates existence; nodes/edges never cross a scope; an edge's OWN visibility_scope
  gates it (a private edge between two visible nodes is omitted); bounds clamp;
  order is deterministic.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Neighborhood

  setup do
    center = add_node!(%{type: "concept", scope: "public"})
    pub = add_node!(%{type: "article", scope: "public"})
    grp = add_node!(%{type: "article", scope: "group"})
    priv = add_node!(%{type: "file", scope: "private"})

    # center → pub (public), center → grp (group), center → priv (private)
    {:ok, _} = Graph.add_edge(center, pub, "mentions", "e1", reliability: 0.9, scope: "public")
    {:ok, _} = Graph.add_edge(center, grp, "mentions", "e2", reliability: 0.8, scope: "group")
    {:ok, _} = Graph.add_edge(center, priv, "mentions", "e3", reliability: 0.7, scope: "private")

    %{center: center, pub: pub, grp: grp, priv: priv}
  end

  test "in-scope neighborhood: nodes + edges within scope, private excluded", ctx do
    {:ok, r} = Neighborhood.query(ctx.center, scopes: ["public", "group"], depth: 1)

    ids = Enum.map(r.nodes, & &1.id) |> Enum.sort()
    assert ids == Enum.sort([ctx.pub, ctx.grp])
    refute ctx.priv in ids
    assert Enum.all?(r.nodes, &(&1.scope in ["public", "group"]))
    # the private edge center→priv is pruned; the two visible edges remain
    relations = Enum.map(r.edges, &{&1.src_id, &1.dst_id})
    assert {ctx.center, ctx.pub} in relations
    assert {ctx.center, ctx.grp} in relations
    refute {ctx.center, ctx.priv} in relations
    refute r.truncated
  end

  test "out-of-scope center ⇒ :not_found (existence not revealed)", ctx do
    assert Neighborhood.query(ctx.priv, scopes: ["public"]) == {:error, :not_found}
    # and an absent id is the same outcome (timing-uniform by construction)
    assert Neighborhood.query(999_999, scopes: ["public"]) == {:error, :not_found}
  end

  test "empty scopes ⇒ :not_found (default-deny)", ctx do
    assert Neighborhood.query(ctx.center, scopes: []) == {:error, :not_found}
  end

  test "an edge's OWN visibility_scope gates it, even between two visible nodes", ctx do
    # both endpoints public + reachable, but the edge between them is private
    {:ok, _} =
      Graph.add_edge(ctx.pub, ctx.center, "links_to", "e4", reliability: 0.5, scope: "private")

    {:ok, r} = Neighborhood.query(ctx.center, scopes: ["public"], depth: 1)
    # pub is reachable via the public center→pub edge
    assert ctx.pub in Enum.map(r.nodes, & &1.id)
    # but the private pub→center edge must NOT appear
    refute {ctx.pub, ctx.center} in Enum.map(r.edges, &{&1.src_id, &1.dst_id})
  end

  test "relation_types filters the projected edges", ctx do
    {:ok, _} =
      Graph.add_edge(ctx.center, ctx.pub, "cites", "e5", reliability: 0.6, scope: "public")

    {:ok, r} =
      Neighborhood.query(ctx.center, scopes: ["public"], depth: 1, relation_types: ["cites"])

    assert Enum.all?(r.edges, &(&1.relation == "cites"))
    assert Enum.any?(r.edges, &(&1.relation == "cites"))
  end

  test "depth and node_limit are clamped; over-limit ⇒ truncated", ctx do
    # node_limit 1 keeps only the strongest neighbor (pub, reliability 0.9) → truncated
    {:ok, r} =
      Neighborhood.query(ctx.center, scopes: ["public", "group"], depth: 5, node_limit: 1)

    assert length(r.nodes) == 1
    assert hd(r.nodes).id == ctx.pub
    assert r.truncated
  end

  test "deterministic order: nodes by confidence desc then id", ctx do
    {:ok, r} = Neighborhood.query(ctx.center, scopes: ["public", "group"], depth: 1)
    confs = Enum.map(r.nodes, & &1.confidence)
    assert confs == Enum.sort(confs, :desc)
    # pub (0.9) ranks before grp (0.8)
    assert Enum.map(r.nodes, & &1.id) == [ctx.pub, ctx.grp]
  end
end
