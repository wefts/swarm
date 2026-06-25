defmodule Swarm.Enrichment.WorkerTest do
  @moduledoc """
  Workspace ADR-13 / EOS-4, EW-2 — the enrichment worker extracts S-P-O claims and
  writes them as `claim`-kind assertion edges. The LLM is mocked (`:gen_fun`) so the
  parse + write + guard logic is deterministic (no 120 s round-trip).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.Worker
  alias Swarm.Graph.Corroboration
  alias Swarm.Ingest.Content
  alias Swarm.Repo

  # A gen_fun returning a fixed claims JSON; records that it was called.
  defp gen_returning(json) do
    test = self()

    fn _model, _prompt, _opts ->
      send(test, :gen_called)
      {:ok, json}
    end
  end

  defp source_with_body(body, attrs \\ %{}) do
    id = add_node!(Map.merge(%{type: "article", scope: "public"}, attrs))
    :ok = Content.put_body(id, body)
    id
  end

  defp claim_edges do
    Repo.query!(
      "SELECT e.type, e.evidence_kind, ep.origin, ns.key AS subj, nd.key AS obj " <>
        "FROM edge e JOIN edge_provenance ep ON ep.edge_id = e.id " <>
        "JOIN node ns ON ns.id = e.src JOIN node nd ON nd.id = e.dst"
    ).rows
  end

  describe "enrich/2" do
    test "extracts triples and writes them as claim-kind assertion edges" do
      node = source_with_body("Paris is the capital of France.")

      gen =
        gen_returning(~s({"claims":[{"s":"Paris","p":"located_in","o":"France"}]}))

      assert {:ok, %{claims: 1, edges: 1}} = Worker.enrich(node, gen_fun: gen)
      assert_received :gen_called

      assert [[type, evidence_kind, origin, subj, obj]] = claim_edges()
      assert type == "located_in"
      assert evidence_kind == "claim"
      assert origin == "enrich:origin:node:#{node}"
      assert subj == "Paris"
      assert obj == "France"
    end

    test "claims inherit the source node's scope" do
      node = source_with_body("group secret relation.", %{scope: "group"})
      gen = gen_returning(~s({"claims":[{"s":"A","p":"relates_to","o":"B"}]}))

      assert {:ok, %{edges: 1}} = Worker.enrich(node, gen_fun: gen)

      %{rows: [[scope]]} = Repo.query!("SELECT visibility_scope FROM edge LIMIT 1")
      assert scope == "group"
      %{rows: scopes} = Repo.query!("SELECT DISTINCT scope FROM node WHERE type = 'entity'")
      assert scopes == [["group"]]
    end

    test "ZONE GUARD: a generated-kind node is never enriched (no LLM call)" do
      node = add_node!(%{type: "concept", scope: "public", kind: "claim"})
      :ok = Content.put_body(node, "some claim text")

      gen = gen_returning(~s({"claims":[{"s":"X","p":"is_a","o":"Y"}]}))

      assert {:skip, :generated_zone} = Worker.enrich(node, gen_fun: gen)
      refute_received :gen_called
      assert claim_edges() == []
    end

    test "a node with no body is skipped" do
      node = add_node!(%{type: "article", scope: "public"})
      gen = gen_returning(~s({"claims":[]}))

      assert {:skip, :no_body} = Worker.enrich(node, gen_fun: gen)
      refute_received :gen_called
    end

    test "a generation failure fails loud (distinct from zero claims)" do
      node = source_with_body("text")
      gen = fn _m, _p, _o -> {:error, :down} end

      assert {:error, {:generation_failed, :down}} = Worker.enrich(node, gen_fun: gen)
    end

    test "malformed triples are dropped; valid ones are kept" do
      node = source_with_body("mixed quality text")

      gen =
        gen_returning(
          ~s({"claims":[{"s":"Paris","p":"located_in","o":"France"},) <>
            ~s({"s":"X","p":"","o":"Y"},{"s":"","p":"is_a","o":"Z"}]})
        )

      # 3 parsed, but the empty-predicate and blank-subject triples drop → 1 edge.
      assert {:ok, %{claims: 3, edges: 1}} = Worker.enrich(node, gen_fun: gen)
      assert length(claim_edges()) == 1
    end

    test "a non-existent node is a typed error" do
      assert {:error, :no_such_node} = Worker.enrich(999_999)
    end

    test "two sources making the SAME claim do not over-corroborate (claims collapse)" do
      n1 = source_with_body("source one text")
      n2 = source_with_body("source two text")
      gen = gen_returning(~s({"claims":[{"s":"Paris","p":"located_in","o":"France"}]}))

      {:ok, _} = Worker.enrich(n1, gen_fun: gen)
      {:ok, _} = Worker.enrich(n2, gen_fun: gen)

      # One edge (same natural key), reinforced by two distinct claim origins.
      %{rows: [[seen]]} = Repo.query!("SELECT seen_count FROM edge WHERE type = 'located_in'")
      assert seen == 2

      # Corroboration collapses the two CLAIM origins to one group (max), so France
      # is NOT corroborated as if by two independent witnesses: it stays at the
      # single claim prior (0.5), not noisy-OR(0.5,0.5)=0.75.
      %{rows: [[france]]} =
        Repo.query!("SELECT id FROM node WHERE type='entity' AND key='France'")

      assert_in_delta Corroboration.node(france, scopes: ["public"]), 0.5, 0.02
    end
  end
end
