defmodule Swarm.Ingest.DeadLetterTest do
  @moduledoc """
  T10 — poison traces are quarantined to the dead-letter zone with a reason, never
  silently dropped and never raised into the pipeline; dependent ingest keeps
  running after a poison event.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Ingest
  alias Swarm.Ingest.DeadLetter

  defp good_event(key) do
    %{
      provenance: key,
      occurred_at: DateTime.utc_now(),
      entities: [%{type: "file", key: key, scope: "private", content: "x"}],
      relations: []
    }
  end

  test "a malformed event (bad timestamp) is quarantined with a reason" do
    poison = %{provenance: "p1", occurred_at: "not-a-timestamp", entities: [], relations: []}

    assert {:error, {:quarantined, _reason}} = Ingest.ingest(poison)
    assert DeadLetter.count() == 1
    assert [%{reason: reason}] = DeadLetter.recent(1)
    assert reason =~ "bad_timestamp"
  end

  test "a contract-violating entity (bad type) is quarantined, NOT raised" do
    poison = %{
      provenance: "p2",
      occurred_at: DateTime.utc_now(),
      # uppercase type violates the ADR-4 contract → upsert_node fails loud
      entities: [%{type: "BadType", key: "k", scope: "private", content: "x"}],
      relations: []
    }

    assert {:error, {:quarantined, {:contract, _}}} = Ingest.ingest(poison)
    assert DeadLetter.count() == 1
  end

  test "the pipeline keeps running after a poison event" do
    assert {:error, {:quarantined, _}} =
             Ingest.ingest(%{provenance: "p3", occurred_at: "bad", entities: [], relations: []})

    # a good event right after still ingests — one poison trace did not stall ingest
    assert {:ok, :written} = Ingest.ingest(good_event("/docs/ok.md"))
    assert DeadLetter.count() == 1
  end

  test "a poison relation rolls back the WHOLE event — no half-write" do
    poison = %{
      provenance: "p-multi",
      occurred_at: DateTime.utc_now(),
      entities: [
        %{type: "file", key: "a.md", scope: "private", content: "x"},
        %{type: "file", key: "b.md", scope: "private", content: "y"}
      ],
      relations: [
        %{from: "a.md", to: "b.md", type: "mentions"},
        # second relation is poison (bad type) — must roll back relation #1 + both entities
        %{from: "a.md", to: "b.md", type: "BadType"}
      ]
    }

    assert {:error, {:quarantined, {:contract, _}}} = Ingest.ingest(poison)
    assert DeadLetter.count() == 1

    %{rows: [[nodes]]} = Swarm.Repo.query!("SELECT count(*) FROM node")
    %{rows: [[edges]]} = Swarm.Repo.query!("SELECT count(*) FROM edge")
    assert nodes == 0
    assert edges == 0
  end

  test "a missing provenance is quarantined (not a silent drop)" do
    assert {:error, {:quarantined, {:missing, :provenance}}} =
             Ingest.ingest(%{occurred_at: DateTime.utc_now(), entities: [], relations: []})

    assert DeadLetter.count() == 1
  end
end
