defmodule Swarm.DeliberationTest do
  @moduledoc """
  ADR-15 — retained panel-vs-judge deliberations. Persisted only for a
  non-anonymous asker; returned only to the owning viewer whose current scopes
  cover the asking scopes; every other case is `:not_found` (existence never
  revealed). Reaped by TTL or row-cap.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Deliberation

  defp verdict do
    %{
      answer: "synthesized",
      confidence: 0.82,
      disagreement: 0.14,
      panel: [%{model: "qwen3:14b", answer: "take a"}, %{model: "gemma4:31b", answer: "take b"}],
      judge: "llama3.3:70b"
    }
  end

  test "persist then fetch by owner within scope returns the panel view" do
    ref = Deliberation.maybe_persist(verdict(), "alice", ["public", "group"])
    assert ref != ""

    assert {:ok, d} = Deliberation.fetch(ref, "alice", ["public", "group"])
    assert d.answer == "synthesized"
    assert d.confidence == 0.82
    assert d.disagreement == 0.14
    assert d.judge == "llama3.3:70b"
    assert length(d.panel) == 2
    assert %{model: "qwen3:14b", answer: "take a"} in d.panel
    assert is_binary(d.created_at) and d.created_at != ""
  end

  test "an anonymous escalation is not retained (ask_ref empty)" do
    assert Deliberation.maybe_persist(verdict(), "", ["public"]) == ""
    assert Deliberation.fetch("", "", ["public"]) == :not_found
  end

  test "a non-owner viewer ⇒ :not_found (existence not revealed)" do
    ref = Deliberation.maybe_persist(verdict(), "alice", ["public"])
    assert Deliberation.fetch(ref, "bob", ["public"]) == :not_found
  end

  test "current scopes must cover the asking scopes (no stale-auth bypass)" do
    ref = Deliberation.maybe_persist(verdict(), "alice", ["public", "group"])
    # alice has since lost `group` → cannot re-open a group-derived deliberation
    assert Deliberation.fetch(ref, "alice", ["public"]) == :not_found
    # covering scopes still works
    assert {:ok, _} = Deliberation.fetch(ref, "alice", ["public", "group", "private"])
  end

  test "an unknown ask_ref ⇒ :not_found" do
    assert Deliberation.fetch("does-not-exist", "alice", ["public"]) == :not_found
  end

  test "ask_refs are opaque and unique" do
    r1 = Deliberation.maybe_persist(verdict(), "alice", ["public"])
    r2 = Deliberation.maybe_persist(verdict(), "alice", ["public"])
    assert r1 != r2
    # opaque, not an enumerable integer sequence
    refute r1 =~ ~r/^\d+$/
  end

  test "disabled retention is the kill-switch (ask_ref always empty)" do
    prev = Application.get_env(:swarm, :deliberation)
    Application.put_env(:swarm, :deliberation, enabled: false)
    on_exit(fn -> Application.put_env(:swarm, :deliberation, prev) end)

    assert Deliberation.maybe_persist(verdict(), "alice", ["public"]) == ""
  end

  test "reap removes TTL-expired rows, keeps fresh ones" do
    old = Deliberation.maybe_persist(verdict(), "alice", ["public"])

    Swarm.Repo.query!(
      "UPDATE deliberation SET created_at = now() - interval '40 days' WHERE ask_ref = $1",
      [old]
    )

    fresh = Deliberation.maybe_persist(verdict(), "bob", ["public"])

    assert Deliberation.reap(ttl_days: 30, max_rows: 10_000) == 1
    assert Deliberation.fetch(old, "alice", ["public"]) == :not_found
    assert {:ok, _} = Deliberation.fetch(fresh, "bob", ["public"])
  end

  test "reap enforces the row cap (oldest-first)" do
    for v <- ["a", "b", "c"], do: Deliberation.maybe_persist(verdict(), v, ["public"])

    assert Deliberation.reap(ttl_days: 100_000, max_rows: 1) == 2
    %{rows: [[n]]} = Swarm.Repo.query!("SELECT count(*) FROM deliberation")
    assert n == 1
  end
end
