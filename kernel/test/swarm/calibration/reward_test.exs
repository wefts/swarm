defmodule Swarm.Calibration.RewardTest do
  use Swarm.GraphCase, async: false

  alias Swarm.AnswerRecords
  alias Swarm.Calibration.Reward
  alias Swarm.Graph.Store
  alias Swarm.Repo

  @scope Swarm.GraphCase.test_src()

  defp edge_fixture(origin \\ "wiki", suffix \\ "alpha") do
    src = Store.upsert_node("entity", "net:host:example-#{suffix}", scope: @scope)
    dst = Store.upsert_node("entity", "net:address:10.20.30.1", scope: @scope)

    {:ok, %{id: edge_id}} =
      Store.add_edge(src, dst, "has_private_address", "prov-#{origin}",
        origin: origin,
        scope: @scope
      )

    edge_id
  end

  defp reward(edge_id) do
    %{rows: [[reward]]} = Repo.query!("SELECT reward FROM edge WHERE id = $1", [edge_id])
    reward
  end

  test "operator helpful and wrong ratings move reward through cited structured evidence" do
    edge_id = edge_fixture()

    ask_ref =
      AnswerRecords.maybe_persist(
        "alice",
        [@scope],
        "what is the private address?",
        %{
          answer: "example answer",
          confidence: 0.8,
          tier: "structured",
          status: :found,
          citations: [%{source: "structured", ref: "net:host:example-alpha", confidence: 1.0}]
        }
      )

    assert AnswerRecords.rate(ask_ref, "alice", [@scope], :helpful) == {:ok, :helpful}
    assert Reward.apply_signal({:rating, ask_ref}) == 1
    assert reward(edge_id) == 0.1

    assert AnswerRecords.rate(ask_ref, "alice", [@scope], :wrong) == {:ok, :wrong}
    assert Reward.apply_signal({:rating, ask_ref}) == 1
    assert reward(edge_id) == -0.9
  end

  test "rating reward applies only to cited structured evidence" do
    edge_id = edge_fixture()
    uncited_edge = edge_fixture("wiki", "beta")

    ask_ref =
      AnswerRecords.maybe_persist(
        "alice",
        [@scope],
        "what is the private address?",
        %{
          answer: "example answer",
          confidence: 0.8,
          tier: "structured",
          status: :found,
          citations: [%{source: "structured", ref: "net:host:example-alpha", confidence: 1.0}]
        }
      )

    assert AnswerRecords.rate(ask_ref, "alice", [@scope], :helpful) == {:ok, :helpful}
    assert Reward.apply_signal({:rating, ask_ref}) == 1
    assert reward(edge_id) == 0.1
    assert reward(uncited_edge) == 0.0
  end

  test "network ratings prefer the asked relation over adjacent cited edges" do
    private_edge = edge_fixture()
    public_dst = Store.upsert_node("entity", "net:address:198.51.100.10", scope: @scope)
    src = Store.upsert_node("entity", "net:host:example-alpha", scope: @scope)

    {:ok, %{id: public_edge}} =
      Store.add_edge(src, public_dst, "has_public_address", "prov-public",
        origin: "wiki",
        scope: @scope
      )

    ask_ref =
      AnswerRecords.maybe_persist(
        "alice",
        [@scope],
        "what is the private address?",
        %{
          answer: "example answer",
          confidence: 0.8,
          tier: "structured",
          status: :found,
          citations: [%{source: "structured", ref: "net:host:example-alpha", confidence: 1.0}]
        }
      )

    assert AnswerRecords.rate(ask_ref, "alice", [@scope], :wrong) == {:ok, :wrong}
    assert Reward.apply_signal({:rating, ask_ref}) == 1
    assert reward(private_edge) == -1.0
    assert reward(public_edge) == 0.0
  end

  test "independent derivation corroboration and contradiction move reward" do
    edge_id = edge_fixture()

    assert Reward.apply_signal(
             {:derivation,
              %{
                verdict: :corroborated,
                subject: "net:host:example-alpha",
                relation: "has_private_address"
              }}
           ) == 1

    assert reward(edge_id) == 0.15

    assert Reward.apply_signal(
             {:derivation,
              %{
                verdict: :contradicted,
                subject: "net:host:example-alpha",
                relation: "has_private_address"
              }}
           ) == 1

    assert reward(edge_id) == -0.85
  end

  test "derivation reward ignores generated-only graph edges" do
    src = Store.upsert_node("entity", "net:host:example-alpha", scope: @scope)
    dst = Store.upsert_node("entity", "net:address:10.20.30.1", scope: @scope)

    {:ok, %{id: edge_id}} =
      Store.add_edge(src, dst, "has_private_address", "prov-claim",
        origin: "answer:ref",
        scope: @scope,
        evidence_kind: "claim"
      )

    assert Reward.apply_signal(
             {:derivation,
              %{
                verdict: :corroborated,
                subject: "net:host:example-alpha",
                relation: "has_private_address"
              }}
           ) == 0

    assert reward(edge_id) == 0.0
  end

  test "authoritative source precedence rewards matching provenance" do
    iac_edge = edge_fixture("iac")
    wiki_edge = edge_fixture("wiki", "beta")

    assert Reward.apply_signal({:authoritative_source, "iac"}) == 1
    assert reward(iac_edge) == 0.2
    assert reward(wiki_edge) == 0.0
  end

  test "the system's own answer alone never mints reward" do
    edge_id = edge_fixture()

    assert Reward.apply_signal({:self_answer, "ask-ref"}) == 0
    assert reward(edge_id) == 0.0
  end
end
