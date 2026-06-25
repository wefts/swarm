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
    # `entity_resolution_audit` has no FK to node (it must outlive a merged-away
    # node), so it is not reached by the CASCADE — truncate it explicitly.
    # `enrichment_watermark` is reached via its node FK, but list it for clarity.
    Swarm.Repo.query!(
      "TRUNCATE node, edge, edge_provenance, content, chunk, node_alias, outbox, dead_letter, stagnant, enrichment_watermark, entity_resolution_audit RESTART IDENTITY CASCADE"
    )

    # Reset the stigmergy cursor (the singleton row survives TRUNCATE of outbox).
    Swarm.Repo.query!("UPDATE outbox_cursor SET position = 0 WHERE id = 1")
    # Reset the in-memory dedup pre-filter so reused provenance keys are fresh.
    if :ets.whereis(Swarm.Ingest.Dedup) != :undefined do
      :ets.delete_all_objects(Swarm.Ingest.Dedup)
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
