defmodule Swarm.Gate.VisibilityTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Gate.Visibility

  # anchor --public--> pub(public) ; anchor --private--> priv(private)
  setup do
    anchor = add_node!(%{type: "anchor", scope: "public"})
    pub = add_node!(%{type: "x", scope: "public"})
    priv = add_node!(%{type: "y", scope: "private"})
    {:ok, _} = Graph.add_edge(anchor, pub, "rel", "e1", scope: "public")
    {:ok, _} = Graph.add_edge(anchor, priv, "rel", "e2", scope: "private")
    %{anchor: anchor, pub: pub, priv: priv}
  end

  test "a public-only context cannot see private nodes (no cross-context leak)", ctx do
    ids = ctx.anchor |> Visibility.visible_neighbors(2, ["public"]) |> Enum.map(& &1.id)
    assert ids == [ctx.pub]
    refute ctx.priv in ids
  end

  test "a context allowed both scopes sees both", ctx do
    ids =
      ctx.anchor
      |> Visibility.visible_neighbors(2, ["public", "private"])
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert ids == Enum.sort([ctx.pub, ctx.priv])
  end

  test "default-deny: no allowed scopes ⇒ nothing visible", ctx do
    assert Visibility.visible_neighbors(ctx.anchor, 2, []) == []
  end
end
