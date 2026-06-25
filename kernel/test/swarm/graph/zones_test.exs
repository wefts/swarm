defmodule Swarm.Graph.ZonesTest do
  @moduledoc """
  T12 (N3 fix) — graph zones + claim/observation typing + reward-gated persistence.
  An LLM claim must never count as independent corroboration, and a refuted trace
  must not linger as ground for the next worker.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Confidence
  alias Swarm.Graph.Contract
  alias Swarm.Graph.GC
  alias Swarm.Graph.Store
  alias Swarm.Repo

  describe "claim vs observation typing (the N3 defense)" do
    test "co-located claims are NOT independent corroboration; observations are" do
      # three LLM claims of 0.8 collapse to ONE group → 0.8 (not inflated)
      assert_in_delta Confidence.combine_typed([
                        {0.8, "claim"},
                        {0.8, "claim"},
                        {0.8, "claim"}
                      ]),
                      0.8,
                      1.0e-9

      # two external observations of 0.8 DO corroborate (noisy-OR → 0.96)
      assert_in_delta Confidence.combine_typed([{0.8, "observation"}, {0.8, "observation"}]),
                      0.96,
                      1.0e-9
    end

    test "ANY generated kind (claim/hypothesis/derived) is non-independent" do
      # mixed generated kinds still collapse to one group → max, not inflated
      assert_in_delta Confidence.combine_typed([
                        {0.8, "claim"},
                        {0.7, "hypothesis"},
                        {0.6, "derived"}
                      ]),
                      0.8,
                      1.0e-9
    end

    test "claim and observation nodes are typed distinctly" do
      obs = add_node!(%{type: "file", scope: "public", kind: "observation"})
      claim = add_node!(%{type: "concept", scope: "public", kind: "claim"})

      %{rows: [[ok]]} = Repo.query!("SELECT kind FROM node WHERE id = $1", [obs])
      %{rows: [[ck]]} = Repo.query!("SELECT kind FROM node WHERE id = $1", [claim])
      assert ok == "observation"
      assert ck == "claim"
    end

    test "an unknown kind is rejected by the contract" do
      assert {:error, cs} = Graph.add_node(%{type: "file", scope: "public", kind: "bogus"})
      refute cs.valid?
    end
  end

  describe "reward-gated persistence" do
    test "a refuted trace (reward < 0) is reaped regardless of freshness" do
      a = add_node!(%{type: "file", scope: "public"})
      b = add_node!(%{type: "concept", scope: "public"})
      {:ok, _good} = Graph.add_edge(a, b, "good", "p1")
      {:ok, refuted} = Graph.add_edge(a, b, "bad", "p2")

      # external ground-truth refutes the second trace
      :ok = Store.set_reward(refuted.id, -1.0)

      # both are fresh, but the refuted one is reaped (not the decay path)
      assert GC.reap(floor: 0.05) == 1
      %{rows: [[type]]} = Repo.query!("SELECT type FROM edge")
      assert type == "good"
    end

    test "a refuted trace is not traversable at READ time (before any GC)" do
      a = add_node!(%{type: "file", scope: "public"})
      b = add_node!(%{type: "concept", scope: "public"})
      {:ok, e} = Graph.add_edge(a, b, "mentions", "p1", scope: "public")

      reachable? = fn -> Enum.any?(Graph.traverse(a, 3, scopes: ["public"]), &(&1.id == b)) end
      assert reachable?.()

      :ok = Store.set_reward(e.id, -1.0)
      # immediately not used as ground — no GC cycle needed
      refute reachable?.()
    end
  end

  describe "schema v1 → v2 round-trip (ADR-4 version policy)" do
    test "a row written WITHOUT the kind column (pre-v2 style) reads back the default" do
      # simulate pre-migration data: a raw insert omitting `kind` (as old v1 rows
      # were, then backfilled by the migration default). It must read cleanly at v2.
      %{rows: [[id]]} =
        Repo.query!("INSERT INTO node (type, scope) VALUES ('file', 'public') RETURNING id")

      %{rows: [[kind]]} = Repo.query!("SELECT kind FROM node WHERE id = $1", [id])
      assert kind == "observation"
    end

    test "the schema version is now 4 (bumped by the evidence-origin migration)" do
      assert Contract.stamped_version() == 5
      assert Contract.schema_version() == 5
    end
  end
end
