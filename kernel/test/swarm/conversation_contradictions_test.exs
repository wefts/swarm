defmodule Swarm.ConversationContradictionsTest do
  use ExUnit.Case, async: true

  alias Swarm.ConversationContradictions

  test "annotates a recommendation reversal from a prior assistant turn" do
    prior = [
      %{role: "user", body: "Which runner should I use?"},
      %{role: "assistant", body: "Use Beta Runner for most jobs and avoid Alpha Runner."}
    ]

    answer = %{
      answer: "Alpha Runner is recommended for general workloads.",
      confidence: 0.8,
      status: :found
    }

    annotated = ConversationContradictions.maybe_annotate(answer, prior)

    assert annotated.answer =~ "Correction:"
    assert annotated.answer =~ "earlier answer was wrong"
    assert annotated.answer =~ "Alpha Runner is recommended"
  end

  test "leaves non-conflicting answers unchanged" do
    prior = [%{role: "assistant", body: "Use Beta Runner for most jobs."}]
    answer = %{answer: "Beta Runner is recommended.", confidence: 0.8, status: :found}

    assert ConversationContradictions.maybe_annotate(answer, prior) == answer
  end

  test "keeps mixed use-and-avoid clauses separate" do
    prior = [
      %{role: "assistant", body: "Use Beta Runner for most jobs and avoid Alpha Runner."}
    ]

    beta = %{answer: "Beta Runner is recommended.", confidence: 0.8, status: :found}

    refute ConversationContradictions.maybe_annotate(beta, prior).answer =~ "Correction:"
  end

  test "annotates a capability reversal from lacks to provides" do
    prior = [
      %{role: "assistant", body: "Avoid Kubernetes runners because they lack S3-backed cache."}
    ]

    answer = %{
      answer: "The Kubernetes runner provides an S3-compatible shared cache.",
      confidence: 0.8,
      status: :found
    }

    annotated = ConversationContradictions.maybe_annotate(answer, prior)

    assert annotated.answer =~ "Correction:"
    assert annotated.answer =~ "earlier answer was wrong"
    assert annotated.answer =~ "Kubernetes runner provides"
  end

  test "does not annotate not-found answers" do
    prior = [%{role: "assistant", body: "Avoid Alpha Runner."}]
    answer = %{answer: "I found nothing.", confidence: 0.0, status: :not_found}

    assert ConversationContradictions.maybe_annotate(answer, prior) == answer
  end
end
