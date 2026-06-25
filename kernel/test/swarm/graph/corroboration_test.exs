defmodule Swarm.Graph.CorroborationTest do
  @moduledoc """
  Workspace ADR-13 EOS-2 (refined by EW-1) — node-local evidential corroboration is
  the production caller of `Confidence.combine_typed/1`. The contribution kind comes
  from the EDGE's `evidence_kind` (what the assertion contributes), not the source
  node's kind. These prove the read-path semantics: independent typed origins
  corroborate (noisy-OR), co-located LLM claims do not, and N derivatives of ONE
  origin collapse to one contribution (the distinct-origin count never leaks back in
  as "more rows ⇒ more belief").
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Corroboration
  alias Swarm.Graph.Store

  @scopes ["public"]

  defp assert_corroboration(node_id, expected) do
    assert_in_delta Corroboration.node(node_id, scopes: @scopes), expected, 0.02
  end

  # An assertion edge src -> dst at 0.8, tagged by its evidence_kind and origin.
  defp assert_edge(src, dst, prov, opts) do
    {:ok, _} =
      Store.add_edge(src, dst, "asserts", prov,
        scope: "public",
        reliability: 0.8,
        origin: Keyword.fetch!(opts, :origin),
        evidence_kind: Keyword.fetch!(opts, :evidence_kind)
      )
  end

  describe "node-local corroboration (ADR-13 EOS-2 / EW-1)" do
    test "two INDEPENDENT external origins corroborate (noisy-OR → 0.96)" do
      t = add_node!(%{type: "concept", scope: "public"})
      o1 = add_node!(%{type: "source", scope: "public"})
      o2 = add_node!(%{type: "source", scope: "public"})

      assert_edge(o1, t, "ev1", origin: "src-1", evidence_kind: "observation")
      assert_edge(o2, t, "ev2", origin: "src-2", evidence_kind: "observation")

      # 0.8 ⊕ 0.8 = 1 - 0.2·0.2 = 0.96
      assert_corroboration(t, 0.96)
    end

    test "N co-located CLAIMS do NOT inflate (one shared-ancestor group → 0.8)" do
      t = add_node!(%{type: "concept", scope: "public"})

      for i <- 1..3 do
        c = add_node!(%{type: "concept", scope: "public"})
        assert_edge(c, t, "ev#{i}", origin: "claim-#{i}", evidence_kind: "claim")
      end

      assert_corroboration(t, 0.8)
    end

    test "N derivatives of ONE origin collapse to a single contribution (→ 0.8)" do
      t = add_node!(%{type: "concept", scope: "public"})
      o1 = add_node!(%{type: "source", scope: "public"})
      o2 = add_node!(%{type: "source", scope: "public"})

      # Two distinct emission events from two nodes, but ONE evidential origin.
      assert_edge(o1, t, "ev1", origin: "one-source", evidence_kind: "observation")
      assert_edge(o2, t, "ev2", origin: "one-source", evidence_kind: "observation")

      assert_corroboration(t, 0.8)
    end

    test "an independent observation OUTWEIGHS three co-located claims of equal strength" do
      claimed = add_node!(%{type: "concept", scope: "public"})
      observed = add_node!(%{type: "concept", scope: "public"})

      for i <- 1..3 do
        c = add_node!(%{type: "concept", scope: "public"})
        assert_edge(c, claimed, "c#{i}", origin: "claim-#{i}", evidence_kind: "claim")
      end

      o1 = add_node!(%{type: "source", scope: "public"})
      o2 = add_node!(%{type: "source", scope: "public"})
      assert_edge(o1, observed, "o1", origin: "obs-1", evidence_kind: "observation")
      assert_edge(o2, observed, "o2", origin: "obs-2", evidence_kind: "observation")

      # 3 claims = 0.8; 2 independent observations = 0.96. Repetition of claims
      # cannot beat genuine independent evidence.
      assert Corroboration.node(observed, scopes: @scopes) >
               Corroboration.node(claimed, scopes: @scopes)
    end

    test "evidence_kind is the ASSERTION's kind, not the source node's kind (EW-1)" do
      # Same source NODE kind (default observation) for both, but the assertions
      # differ in evidence_kind — corroboration reads the edge, so claims collapse.
      claimed = add_node!(%{type: "concept", scope: "public"})
      observed = add_node!(%{type: "concept", scope: "public"})

      a = add_node!(%{type: "entity", scope: "public"})
      b = add_node!(%{type: "entity", scope: "public"})
      assert_edge(a, claimed, "k1", origin: "o-1", evidence_kind: "claim")
      assert_edge(b, claimed, "k2", origin: "o-2", evidence_kind: "claim")

      c = add_node!(%{type: "entity", scope: "public"})
      d = add_node!(%{type: "entity", scope: "public"})
      assert_edge(c, observed, "k3", origin: "o-3", evidence_kind: "observation")
      assert_edge(d, observed, "k4", origin: "o-4", evidence_kind: "observation")

      # Identical node kinds + identical strengths; only evidence_kind differs.
      assert_corroboration(claimed, 0.8)
      assert_corroboration(observed, 0.96)
    end

    test "a node with no typed assertions is ABSENT (caller falls back to reliability)" do
      t = add_node!(%{type: "concept", scope: "public"})
      assert Corroboration.for_nodes([t], scopes: @scopes) == %{}
    end

    test "STRUCTURAL edges (links_to/child_of) do NOT corroborate (topology ≠ evidence)" do
      t = add_node!(%{type: "article", scope: "public"})
      p1 = add_node!(%{type: "article", scope: "public"})
      p2 = add_node!(%{type: "article", scope: "public"})

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
      t = add_node!(%{type: "concept", scope: "public"})
      o1 = add_node!(%{type: "source", scope: "public"})

      {:ok, e} =
        Store.add_edge(o1, t, "asserts", "ev1",
          scope: "public",
          reliability: 0.8,
          origin: "src-1",
          evidence_kind: "observation"
        )

      :ok = Store.set_reward(e.id, -1.0)
      assert Corroboration.for_nodes([t], scopes: @scopes) == %{}
    end

    test "assertions from out-of-scope sources are not counted (visibility)" do
      t = add_node!(%{type: "concept", scope: "public"})
      pub = add_node!(%{type: "source", scope: "public"})
      grp = add_node!(%{type: "source", scope: "group"})

      assert_edge(pub, t, "ev-pub", origin: "src-pub", evidence_kind: "observation")
      # group-scoped assertion is invisible to a public-only asker
      {:ok, _} =
        Store.add_edge(grp, t, "asserts", "ev-grp",
          scope: "group",
          reliability: 0.8,
          origin: "src-grp",
          evidence_kind: "observation"
        )

      # Only the public origin counts → single contribution → 0.8 (not 0.96).
      assert_corroboration(t, 0.8)
    end

    test "defense-in-depth: a scope-invariant-violating edge does not leak its hidden source" do
      # The edge-scope ≤ endpoints invariant is only write-enforced; simulate a
      # legacy/bypassed row (public edge from a GROUP source) by raw insert. The
      # source-node scope join must still exclude it from a public-only asker
      # (council, codex) — filtering edge scope alone would leak it.
      t = add_node!(%{type: "concept", scope: "public"})
      grp = add_node!(%{type: "source", scope: "group"})

      %{rows: [[eid]]} =
        Repo.query!(
          "INSERT INTO edge (src, dst, type, visibility_scope, weight, reliability, evidence_kind, seen_count) " <>
            "VALUES ($1, $2, 'asserts', 'public', 1.0, 0.8, 'observation', 1) RETURNING id",
          [grp, t]
        )

      Repo.query!(
        "INSERT INTO edge_provenance (edge_id, provenance, origin) VALUES ($1, 'leak-ev', 'leak-src')",
        [eid]
      )

      # The group source must NOT corroborate a public-scoped read.
      assert Corroboration.for_nodes([t], scopes: @scopes) == %{}
    end
  end
end
