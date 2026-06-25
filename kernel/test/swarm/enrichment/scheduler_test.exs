defmodule Swarm.Enrichment.SchedulerTest do
  @moduledoc """
  Workspace ADR-13 / EOS-4 §1c, EW-5 — the bounded worth-it scan and its
  generation-bounded convergence. A pass enriches at most `max_per_pass` worth-it
  nodes (not a blanket reactor); a second pass over unchanged content does nothing
  (fixpoint), because the worker's output is non-enrichable by construction.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.Priority
  alias Swarm.Enrichment.Scheduler
  alias Swarm.Ingest.Content
  alias Swarm.Repo

  defp source(body),
    do: (id = add_node!(%{type: "article", scope: "public"})) && Content.put_body(id, body) && id

  # Each source yields one claim, keyed by node so distinct sources make distinct edges.
  defp gen_per_node do
    test = self()

    fn _model, prompt, _opts ->
      send(test, :gen_called)
      tag = prompt |> :erlang.phash2() |> Integer.to_string()
      {:ok, ~s({"claims":[{"s":"E#{tag}","p":"relates_to","o":"T#{tag}"}]})}
    end
  end

  defp content_count, do: (%{rows: [[n]]} = Repo.query!("SELECT count(*) FROM content")) && n

  defp entity_count,
    do: (%{rows: [[n]]} = Repo.query!("SELECT count(*) FROM node WHERE type='entity'")) && n

  describe "run_pass/1" do
    test "enriches at most max_per_pass worth-it nodes (bounded fan-out, not a blanket reactor)" do
      for i <- 1..8, do: source("source body number #{i} with distinct content")

      # config max_per_pass = 5
      summary = Scheduler.run_pass(gen_fun: gen_per_node())

      assert summary.considered == 8
      assert summary.queued == 5
      assert summary.enriched == 5
    end

    test "converges: a second pass over unchanged content does nothing (fixpoint)" do
      for i <- 1..3, do: source("doc #{i}")

      first = Scheduler.run_pass(gen_fun: gen_per_node())
      assert first.enriched == 3
      assert first.generation == 1

      # The minted entities have no body (not in `content`), so they are not
      # candidates; the sources are now fresh-watermarked → nothing left to do.
      before_entities = entity_count()
      second = Scheduler.run_pass(gen_fun: gen_per_node())

      assert second.considered == 0
      assert second.enriched == 0
      assert second.generation == 2
      # No new nodes minted by the empty second pass.
      assert entity_count() == before_entities
    end

    test "the worker's output is non-enrichable (no worker→graph→worker loop)" do
      node = source("a document that yields claims")
      Scheduler.run_pass(gen_fun: gen_per_node())

      # Every entity the worker minted scores 0 (no body) → never a candidate.
      %{rows: ids} = Repo.query!("SELECT id FROM node WHERE type = 'entity'")
      assert ids != []
      assert Enum.all?(ids, fn [id] -> Priority.score(id) == 0.0 end)

      # content rows did not grow with entities (only the original source has one).
      assert content_count() == 1
      _ = node
    end

    test "a changed source is re-enriched on the next pass (watermark invalidation)" do
      node = source("version one")
      assert Scheduler.run_pass(gen_fun: gen_per_node()).enriched == 1
      assert Scheduler.run_pass(gen_fun: gen_per_node()).enriched == 0

      :ok = Content.put_body(node, "version two — different content entirely")
      # The changed body invalidates the watermark → re-enriched next pass.
      assert Scheduler.run_pass(gen_fun: gen_per_node()).enriched == 1
    end

    test "a candidate already leased by another pass is skipped (per-node lease, no double-spend)" do
      node = source("a doc")

      # Simulate a concurrent pass holding the node's lease.
      Repo.query!(
        "UPDATE node SET claimed_by = 'enrichment', lease_until = now() + interval '5 minutes' WHERE id = $1",
        [node]
      )

      summary = Scheduler.run_pass(gen_fun: gen_per_node())

      assert summary.queued == 1
      assert summary.enriched == 0
      assert summary.skipped_locked == 1
      # No LLM call on a node another pass holds — no duplicate spend.
      refute_received :gen_called
    end
  end
end
