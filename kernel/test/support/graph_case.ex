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
    Swarm.Repo.query!("TRUNCATE node, edge, edge_provenance RESTART IDENTITY CASCADE")
    :ok
  end

  @doc "Insert a node and return its id, raising on validation failure."
  @spec add_node!(map()) :: integer()
  def add_node!(attrs) do
    {:ok, node} = Swarm.Graph.add_node(attrs)
    node.id
  end
end
