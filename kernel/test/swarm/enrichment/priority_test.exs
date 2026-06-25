defmodule Swarm.Enrichment.PriorityTest do
  @moduledoc """
  Workspace ADR-13 / EOS-4 §1b, EW-4 — the worth-it scheduler. Novelty is the hard
  gate (a fresh-watermarked node scores 0, so it cannot be re-queued); among novel
  nodes, centrality and criticality rank them; below-threshold nodes never escalate.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.Priority
  alias Swarm.Enrichment.Watermark
  alias Swarm.Graph.Store
  alias Swarm.Ingest.Content

  defp source(body, attrs \\ %{}) do
    id = add_node!(Map.merge(%{type: "article", scope: "public"}, attrs))
    :ok = Content.put_body(id, body)
    id
  end

  # Mark a node freshly enriched for its CURRENT body + configured policy/model.
  defp watermark_fresh(node_id, body) do
    cfg = Application.get_env(:swarm, :enrichment, [])

    Watermark.record(node_id, %{
      content_hash: Content.body_hash(body),
      policy_version: cfg[:policy_version],
      model: cfg[:model],
      generation: 0,
      state: "fresh"
    })
  end

  describe "score/2 — novelty gate" do
    test "a fresh-watermarked node scores 0 (no re-pay)" do
      body = "Paris is the capital of France."
      node = source(body)
      watermark_fresh(node, body)

      assert Priority.score(node) == 0.0
      refute Priority.worth_it?(node)
    end

    test "a novel source scores > 0 and is worth-it" do
      node = source("unenriched content with facts")
      assert Priority.score(node) > 0.0
      assert Priority.worth_it?(node)
    end

    test "a generated-kind node scores 0 (cannot be enriched)" do
      node = add_node!(%{type: "concept", scope: "public", kind: "claim"})
      :ok = Content.put_body(node, "a claim body")
      assert Priority.score(node) == 0.0
    end

    test "a node with no body scores 0" do
      node = add_node!(%{type: "article", scope: "public"})
      assert Priority.score(node) == 0.0
    end
  end

  describe "score/2 — ranking" do
    test "a hub outscores a leaf (centrality)" do
      hub = source("hub body")
      leaf = source("leaf body")

      # Give the hub outgoing degree (structural links — don't corroborate it).
      for i <- 1..10 do
        t = add_node!(%{type: "article", scope: "public"})
        {:ok, _} = Store.add_edge(hub, t, "links_to", "l#{i}", scope: "public")
      end

      assert Priority.score(hub) > Priority.score(leaf)
    end

    test "a well-corroborated node scores LOWER than an un-corroborated one (criticality)" do
      bare = source("bare body")
      attested = source("attested body")

      # Two independent external observations corroborate `attested`.
      for i <- 1..2 do
        o = add_node!(%{type: "source", scope: "public"})

        {:ok, _} =
          Store.add_edge(o, attested, "asserts", "o#{i}",
            scope: "public",
            reliability: 0.8,
            origin: "obs-#{i}",
            evidence_kind: "observation"
          )
      end

      # Already well-attested ⇒ lower enrichment priority than the bare node.
      assert Priority.score(attested) < Priority.score(bare)
    end
  end

  describe "explain/2 (auditable decision)" do
    test "surfaces every component, score, threshold, and verdict" do
      node = source("unenriched content")
      e = Priority.explain(node)

      assert e.novel == true
      assert is_float(e.central) and e.central >= 0.0
      assert is_float(e.criticality)
      assert e.demand == 0.0
      assert e.score > 0.0
      assert e.worth_it == e.score >= e.threshold
    end

    test "a fresh node's explanation shows the novelty gate (not worth-it)" do
      body = "done"
      node = source(body)
      watermark_fresh(node, body)

      assert %{novel: false, score: +0.0, worth_it: false} = Priority.explain(node)
    end
  end

  describe "queue/2" do
    test "keeps worth-it nodes strongest-first and drops below-threshold" do
      hub = source("hub")

      for i <- 1..10 do
        t = add_node!(%{type: "article", scope: "public"})
        {:ok, _} = Store.add_edge(hub, t, "links_to", "l#{i}", scope: "public")
      end

      leaf = source("leaf")

      fresh_body = "already done"
      fresh = source(fresh_body)
      watermark_fresh(fresh, fresh_body)

      q = Priority.queue([leaf, hub, fresh])

      # fresh (score 0) is dropped; hub ranks above leaf.
      assert [{^hub, _}, {^leaf, _}] = q
    end
  end
end
