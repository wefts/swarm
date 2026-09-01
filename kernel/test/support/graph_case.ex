defmodule Swarm.GraphCase do
  @moduledoc """
  Case template for graph data-layer tests.

  No SQL sandbox on purpose: the CAS concurrency test needs true parallel
  writers with real Postgres row locks, which a single sandboxed connection
  cannot provide. Instead each test truncates the graph tables first and runs
  `async: false` (serialized against the shared schema).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Swarm.{Graph, Repo}

      import Swarm.GraphCase
    end
  end

  setup do
    truncate_graph()
    :ok
  end

  @doc "Wipe the graph tables (and reset ids) so each test starts clean."
  @spec truncate_graph() :: :ok
  def truncate_graph do
    # `entity_resolution_audit` and `enrichment_decision` have no FK to node (they
    # outlive the node — audit trails), so they are not reached by the CASCADE —
    # truncate them explicitly. `enrichment_watermark` is reached via its node FK,
    # but list it for clarity. Calibration tables key by ask_ref / subject, no node FK.
    Swarm.Repo.query!(
      "TRUNCATE node, edge, edge_provenance, content, chunk, node_alias, node_do_not_merge, outbox, dead_letter, stagnant, enrichment_watermark, entity_resolution_audit, enrichment_decision, enrichment_pass, deliberation, calibration_contradiction, answer_rating, answer_record RESTART IDENTITY CASCADE"
    )

    # Reset the stigmergy cursor (the singleton row survives TRUNCATE of outbox).
    Swarm.Repo.query!("UPDATE outbox_cursor SET position = 0 WHERE id = 1")
    # Reset the in-memory dedup pre-filter so reused provenance keys are fresh.
    if :ets.whereis(Swarm.Ingest.Dedup) != :undefined do
      :ets.delete_all_objects(Swarm.Ingest.Dedup)
    end

    :ok
  end

  # Two fixed, well-formed source scopes for graph-layer tests (ADR-20: `src:<uuid>`; the
  # retired `group` scope is no longer admissible). `Store.upsert_node` validates SHAPE only, so
  # these need no registry row; `register_test_sources!/0` registers both for ingest/derivation
  # tests (`Swarm.Projects.registered_scope?/1`).
  @test_src "src:00000000-0000-7000-8000-00000000c0de"
  @test_src2 "src:00000000-0000-7000-8000-00000000c0df"

  @doc "A fixed, well-formed source scope for graph tests (the former `group` fixture)."
  @spec test_src() :: String.t()
  def test_src, do: @test_src

  @doc "A second, distinct fixed source scope (cross-source tests)."
  @spec test_src2() :: String.t()
  def test_src2, do: @test_src2

  @doc "Register Projects + Sources behind `test_src/0` and `test_src2/0` (idempotent)."
  @spec register_test_sources!() :: :ok
  def register_test_sources! do
    for {scope, name} <- [{@test_src, "Test source A"}, {@test_src2, "Test source B"}] do
      id = String.replace_prefix(scope, "src:", "")

      unless Swarm.Projects.registered_scope?(scope) do
        {:ok, p} = Swarm.Projects.create_project(%{name: name})
        {:ok, _} = Swarm.Projects.add_source(p.id, %{kind: "wiki", label: name, id: id})
      end
    end

    :ok
  end

  @doc "Insert a node and return its id, raising on validation failure."
  @spec add_node!(map()) :: integer()
  def add_node!(attrs) do
    {:ok, node} = Swarm.Graph.add_node(attrs)
    node.id
  end
end
