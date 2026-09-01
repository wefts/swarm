defmodule Swarm.AnswerRecordsTest do
  use Swarm.GraphCase, async: false

  alias Swarm.{AnswerRecords, Deliberation}

  defp answer(attrs \\ []) do
    Map.merge(
      %{
        answer: "Example answer.",
        confidence: 0.8,
        tier: "structured",
        status: :found,
        citations: []
      },
      Map.new(attrs)
    )
  end

  test "a non-anonymous answer is recorded and queryable by ask_ref" do
    ask_ref = AnswerRecords.maybe_persist("alice", ["public", test_src()], "what is x?", answer())

    assert ask_ref != ""
    assert {:ok, rec} = AnswerRecords.fetch(ask_ref, "alice", ["public", test_src()])
    assert rec.query == "what is x?"
    assert rec.answer == "Example answer."
    assert rec.tier == "structured"
    assert rec.status == "found"
  end

  test "anonymous answers do not mint a rating handle" do
    assert AnswerRecords.maybe_persist("", ["public"], "what is x?", answer()) == ""
  end

  test "rating round-trips for the owner and is upserted" do
    ask_ref = AnswerRecords.maybe_persist("alice", ["public"], "what is x?", answer())

    assert AnswerRecords.rate(ask_ref, "alice", ["public"], :helpful) == {:ok, :helpful}
    assert AnswerRecords.fetch_rating(ask_ref, "alice") == {:ok, :helpful}

    assert AnswerRecords.rate(ask_ref, "alice", ["public"], "wrong") == {:ok, :wrong}
    assert AnswerRecords.fetch_rating(ask_ref, "alice") == {:ok, :wrong}
  end

  test "rating is owner- and scope-gated with no existence oracle" do
    ask_ref = AnswerRecords.maybe_persist("alice", ["public", test_src()], "what is x?", answer())

    assert AnswerRecords.rate(ask_ref, "bob", ["public", test_src()], :helpful) == :not_found
    assert AnswerRecords.rate(ask_ref, "alice", ["public"], :helpful) == :not_found
    assert AnswerRecords.rate("missing", "alice", ["public"], :helpful) == :not_found
    assert AnswerRecords.rate(ask_ref, "alice", ["public", test_src()], :bogus) == :bad_request
  end

  test "agreement is backfilled from retained deliberation without minting reward" do
    ask_ref =
      Deliberation.maybe_persist(
        %{
          answer: "synthesized",
          confidence: 0.82,
          disagreement: 0.25,
          panel: [%{model: "qwen3:14b", answer: "take"}],
          judge: "gemma4:31b"
        },
        "alice",
        ["public"]
      )

    AnswerRecords.maybe_persist(
      "alice",
      ["public"],
      "what is x?",
      answer(ask_ref: ask_ref, tier: "escalate", agreement: nil)
    )

    assert AnswerRecords.backfill_agreement_from_deliberation() == 1
    assert {:ok, rec} = AnswerRecords.fetch(ask_ref, "alice", ["public"])
    assert rec.agreement == 0.75

    %{rows: [[rewarded]]} = Swarm.Repo.query!("SELECT count(*) FROM edge WHERE reward <> 0")
    assert rewarded == 0
  end
end
