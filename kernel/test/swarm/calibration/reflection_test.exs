defmodule Swarm.Calibration.ReflectionTest do
  use Swarm.GraphCase, async: false

  alias Swarm.AnswerRecords
  alias Swarm.Calibration.Reflection
  alias Swarm.Graph.Network

  @scope Swarm.GraphCase.test_src()

  test "a past escalation is converted into claim-backed structure without judging itself" do
    AnswerRecords.maybe_persist(
      "alice",
      [@scope],
      "What is private IP of example-host?",
      %{
        answer: "The private address is 10.20.30.1.",
        confidence: 0.61,
        tier: "escalate",
        status: :found,
        citations: []
      }
    )

    assert Reflection.run(limit: 10) == %{written: 1, skipped: 0}

    facts =
      Network.neighborhood("net:host:example-host", [@scope],
        min_corroboration: 1,
        relations: ["has_private_address"]
      )

    assert [%{relation: "has_private_address", object: "address/10.20.30.1"}] = facts

    %{rows: [[source_kind, evidence_kind, reward]]} =
      Swarm.Repo.query!("""
      SELECT source.kind, e.evidence_kind, e.reward
        FROM edge e
        JOIN edge_provenance ep ON ep.edge_id = e.id
        JOIN node source ON source.id = ep.source_node_id
       WHERE e.type = 'has_private_address'
      """)

    assert source_kind == "claim"
    assert evidence_kind == "claim"
    assert reward == 0.0
  end
end
