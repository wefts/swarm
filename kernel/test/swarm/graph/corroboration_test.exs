defmodule Swarm.Graph.CorroborationTest do
  @moduledoc """
  Workspace ADR-13 EOS-2 — node-local evidential corroboration is the production
  caller of `Confidence.combine_typed/1`. These prove the read-path semantics:
  independent typed origins corroborate (noisy-OR), co-located LLM claims do not,
  and N derivatives of ONE origin collapse to one contribution (so the
  distinct-origin count never leaks back in as "more rows ⇒ more belief").
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Corroboration
  alias Swarm.Graph.Store

  @scopes ["public"]

  defp assert_corroboration(node_id, expected) do
    assert_in_delta Corroboration.node(node_id, scopes: @scopes), expected, 0.02
  end

  describe "node-local corroboration (ADR-13 EOS-2)" do
    test "two INDEPENDENT external origins corroborate (noisy-OR → 0.96)" do
      t = add_node!(%{type: "concept", scope: "public", kind: "observation"})
      o1 = add_node!(%{type: "source", scope: "public", kind: "observation"})
      o2 = add_node!(%{type: "source", scope: "public", kind: "observation"})

      {:ok, _} =
        Store.add_edge(o1, t, "asserts", "ev1",
          scope: "public",
          reliability: 0.8,
          origin: "src-1"
        )

      {:ok, _} =
        Store.add_edge(o2, t, "asserts", "ev2",
          scope: "public",
          reliability: 0.8,
          origin: "src-2"
        )

      # 0.8 ⊕ 0.8 = 1 - 0.2·0.2 = 0.96
      assert_corroboration(t, 0.96)
    end

    test "N co-located CLAIMS do NOT inflate (one shared-ancestor group → 0.8)" do
      t = add_node!(%{type: "concept", scope: "public"})

      for i <- 1..3 do
        c = add_node!(%{type: "concept", scope: "public", kind: "claim"})

        {:ok, _} =
          Store.add_edge(c, t, "asserts", "ev#{i}",
            scope: "public",
            reliability: 0.8,
            origin: "claim-#{i}"
          )
      end

      assert_corroboration(t, 0.8)
    end

    test "N derivatives of ONE origin collapse to a single contribution (→ 0.8)" do
      t = add_node!(%{type: "concept", scope: "public", kind: "observation"})
      o1 = add_node!(%{type: "source", scope: "public", kind: "observation"})
      o2 = add_node!(%{type: "source", scope: "public", kind: "observation"})

      # Two distinct emission events from two nodes, but ONE evidential origin.
      {:ok, _} =
        Store.add_edge(o1, t, "asserts", "ev1",
          scope: "public",
          reliability: 0.8,
          origin: "one-source"
        )

      {:ok, _} =
        Store.add_edge(o2, t, "asserts", "ev2",
          scope: "public",
          reliability: 0.8,
          origin: "one-source"
        )

      assert_corroboration(t, 0.8)
    end

    test "an independent observation OUTWEIGHS three co-located claims of equal strength" do
      claimed = add_node!(%{type: "concept", scope: "public"})
      observed = add_node!(%{type: "concept", scope: "public"})

      for i <- 1..3 do
        c = add_node!(%{type: "concept", scope: "public", kind: "claim"})

        {:ok, _} =
          Store.add_edge(c, claimed, "asserts", "c#{i}",
            scope: "public",
            reliability: 0.8,
            origin: "claim-#{i}"
          )
      end

      o1 = add_node!(%{type: "source", scope: "public", kind: "observation"})
      o2 = add_node!(%{type: "source", scope: "public", kind: "observation"})

      {:ok, _} =
        Store.add_edge(o1, observed, "asserts", "o1",
          scope: "public",
          reliability: 0.8,
          origin: "obs-1"
        )

      {:ok, _} =
        Store.add_edge(o2, observed, "asserts", "o2",
          scope: "public",
          reliability: 0.8,
          origin: "obs-2"
        )

      # 3 claims = 0.8; 2 independent observations = 0.96. Repetition of claims
      # cannot beat genuine independent evidence.
      assert Corroboration.node(observed, scopes: @scopes) >
               Corroboration.node(claimed, scopes: @scopes)
    end

    test "a node with no typed assertions is ABSENT (caller falls back to reliability)" do
      t = add_node!(%{type: "concept", scope: "public"})
      assert Corroboration.for_nodes([t], scopes: @scopes) == %{}
    end

    test "STRUCTURAL edges (links_to/child_of) do NOT corroborate (topology ≠ evidence)" do
      t = add_node!(%{type: "article", scope: "public", kind: "observation"})
      p1 = add_node!(%{type: "article", scope: "public", kind: "observation"})
      p2 = add_node!(%{type: "article", scope: "public", kind: "observation"})

      # Two independent pages LINK to t — popularity, not evidential corroboration.
      {:ok, _} =
        Store.add_edge(p1, t, "links_to", "l1",
          scope: "public",
          reliability: 0.8,
          origin: "page-1"
        )

      {:ok, _} =
        Store.add_edge(p2, t, "child_of", "l2",
          scope: "public",
          reliability: 0.8,
          origin: "page-2"
        )

      assert Corroboration.for_nodes([t], scopes: @scopes) == %{}
    end

    test "a refuted assertion (reward < 0) does not corroborate" do
      t = add_node!(%{type: "concept", scope: "public", kind: "observation"})
      o1 = add_node!(%{type: "source", scope: "public", kind: "observation"})

      {:ok, e} =
        Store.add_edge(o1, t, "asserts", "ev1",
          scope: "public",
          reliability: 0.8,
          origin: "src-1"
        )

      :ok = Store.set_reward(e.id, -1.0)
      assert Corroboration.for_nodes([t], scopes: @scopes) == %{}
    end

    test "assertions from out-of-scope sources are not counted (visibility)" do
      t = add_node!(%{type: "concept", scope: "public", kind: "observation"})
      pub = add_node!(%{type: "source", scope: "public", kind: "observation"})
      grp = add_node!(%{type: "source", scope: "group", kind: "observation"})

      {:ok, _} =
        Store.add_edge(pub, t, "asserts", "ev-pub",
          scope: "public",
          reliability: 0.8,
          origin: "src-pub"
        )

      # group-scoped assertion is invisible to a public-only asker
      {:ok, _} =
        Store.add_edge(grp, t, "asserts", "ev-grp",
          scope: "group",
          reliability: 0.8,
          origin: "src-grp"
        )

      # Only the public origin counts → single contribution → 0.8 (not 0.96).
      assert_corroboration(t, 0.8)
    end
  end
end
