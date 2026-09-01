defmodule Swarm.Calibration.ContradictionsTest do
  use Swarm.GraphCase, async: false

  alias Swarm.AnswerRecords
  alias Swarm.Calibration.Contradictions
  alias Swarm.Enrichment.NetworkMap
  alias Swarm.Graph.Store

  @scope Swarm.GraphCase.test_src()

  defp src_node do
    %{id: Store.upsert_node("article", "calibration-source", scope: @scope), scope: @scope}
  end

  defp seed_private_address do
    NetworkMap.write(
      src_node(),
      [
        %{
          subject: "example-site",
          subject_kind: "host",
          relation: "has_address",
          object: "10.20.30.1",
          object_kind: "address"
        }
      ],
      "prov-calibration-network"
    )
  end

  test "a broader private subnet answer corroborates a graph host address" do
    seed_private_address()

    ref =
      AnswerRecords.maybe_persist(
        "alice",
        [@scope],
        "What is example-site private IP?",
        %{
          answer: "The private network is 10.20.0.0/16.",
          confidence: 0.7,
          tier: "escalate",
          status: :found,
          citations: []
        }
      )

    result =
      Contradictions.classify(%{
        ask_ref: ref,
        query: "What is example-site private IP?",
        answer: "The private network is 10.20.0.0/16.",
        scopes: [@scope]
      })

    assert result.verdict == :corroborated
    assert result.relation == "has_private_address"
    assert result.explanation =~ "broader CIDR"
  end

  test "a different private subnet contradicts the graph address" do
    seed_private_address()

    result =
      Contradictions.classify(%{
        ask_ref: "ref-contradict",
        query: "What is example-site private IP?",
        answer: "The private network is 10.99.0.0/16.",
        scopes: [@scope]
      })

    assert result.verdict == :contradicted
  end

  test "a different private host address contradicts the graph address" do
    seed_private_address()

    result =
      Contradictions.classify(%{
        ask_ref: "ref-contradict-ip",
        query: "What is example-site private IP?",
        answer: "The private address is 10.99.30.1.",
        scopes: [@scope]
      })

    assert result.verdict == :contradicted
  end

  test "run only compares escalated answers" do
    seed_private_address()

    AnswerRecords.maybe_persist(
      "alice",
      [@scope],
      "What is example-site private IP?",
      %{
        answer: "host example-site:\nhas_private_address address/10.20.30.1",
        confidence: 0.9,
        tier: "tier_tools",
        status: :found,
        citations: [%{source: "structured", ref: "net:host:example-site", confidence: 1.0}]
      }
    )

    assert %{results: []} = Contradictions.run()
  end

  test "classification prefers the cited network subject over a fresh candidate lookup" do
    seed_private_address()

    other = Store.upsert_node("entity", "net:host:example-site-shadow", scope: @scope)
    other_addr = Store.upsert_node("entity", "net:address:10.99.30.1", scope: @scope)

    {:ok, _} =
      Store.add_edge(other, other_addr, "has_private_address", "prov-shadow",
        scope: @scope,
        origin: "iac-shadow"
      )

    result =
      Contradictions.classify(%{
        ask_ref: "ref-cited",
        query: "What is example-site private IP?",
        answer: "The private network is 10.20.0.0/16.",
        scopes: [@scope],
        citations: [%{ref: "net:host:example-site"}]
      })

    assert result.verdict == :corroborated
    assert result.subject == "net:host:example-site"
  end

  test "unsupported relations are not comparable" do
    result =
      Contradictions.classify(%{
        ask_ref: "ref-other",
        query: "Who operates example-site?",
        answer: "Alice.",
        scopes: [@scope]
      })

    assert result.verdict == :not_comparable
  end

  test "a reflection claim from the same answer does not corroborate itself" do
    ref = "ref-self"
    source = Store.upsert_node("concept", "answer:#{ref}", scope: @scope)
    subj = Store.upsert_node("entity", "net:host:example-site", scope: @scope)
    dst = Store.upsert_node("entity", "net:address:10.20.30.1", scope: @scope)

    {:ok, _} =
      Store.add_edge(subj, dst, "has_private_address", "reflection:#{ref}:private-address",
        scope: @scope,
        origin: "answer:#{ref}",
        source_node_id: source,
        reliability: 0.45,
        evidence_kind: "claim"
      )

    result =
      Contradictions.classify(%{
        ask_ref: ref,
        query: "What is example-site private IP?",
        answer: "The private address is 10.20.30.1.",
        scopes: [@scope]
      })

    assert result.verdict == :not_comparable
  end

  test "a reflection claim from another answer does not count as independent corroboration" do
    ref = "ref-later"
    source = Store.upsert_node("concept", "answer:ref-earlier", scope: @scope)
    subj = Store.upsert_node("entity", "net:host:example-site", scope: @scope)
    dst = Store.upsert_node("entity", "net:address:10.20.30.1", scope: @scope)

    {:ok, _} =
      Store.add_edge(subj, dst, "has_private_address", "reflection:ref-earlier:private-address",
        scope: @scope,
        origin: "answer:ref-earlier",
        source_node_id: source,
        reliability: 0.45,
        evidence_kind: "claim"
      )

    result =
      Contradictions.classify(%{
        ask_ref: ref,
        query: "What is example-site private IP?",
        answer: "The private address is 10.20.30.1.",
        scopes: [@scope]
      })

    assert result.verdict == :not_comparable
  end
end
