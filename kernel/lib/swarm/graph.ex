defmodule Swarm.Graph do
  @moduledoc """
  Facade over the knowledge-graph substrate (Task 02). Thin delegation to the
  focused modules; the invariants live in the DDL and the modules below.

  - `Swarm.Graph.Store` — `add_node`, `add_edge` (insert-or-increment, ADR-9)
  - `Swarm.Graph.Coordination` — `claim`/`renew_lease`/`read_fences` (ADR-1/2)
  - `Swarm.Graph.Traverse` — bounded walk with decay + path confidence
  - `Swarm.Graph.Confidence` — ADR-3 algebra (pure)
  - `Swarm.Graph.Strength` — ADR-9 saturation + decay (pure)
  """

  alias Swarm.Graph.{Coordination, Store, Traverse}

  defdelegate add_node(attrs), to: Store
  defdelegate add_edge(src, dst, type, provenance, opts \\ []), to: Store
  defdelegate claim(node_id, worker, token, opts \\ []), to: Coordination

  defdelegate renew_lease(node_id, worker, fence, observed_lease_until, opts \\ []),
    to: Coordination

  defdelegate read_fences(node_ids), to: Coordination
  defdelegate traverse(start_id, max_depth, opts \\ []), to: Traverse
end
