defmodule Swarm.Gate.Visibility do
  @moduledoc """
  THE single visibility enforcement point (ADR-5 / Domain 15). Closes the
  scope-authority finding from the Task 02 review.

  **Pinned authority rule (default-deny, BOTH):**
  - a relation is traversable only if `edge.visibility_scope` ∈ the context's
    allowed-scope set;
  - a node is disclosable only if `node.scope` ∈ the allowed set.

  Ingestion keeps `edge.visibility_scope` ≤ the narrowest endpoint scope, so the
  two always agree; enforcing both is fail-safe. An empty/absent allowed set ⇒
  nothing is visible.

  `Swarm.Graph.Traverse` is the MECHANISM — it prunes both at the index when
  given `:scopes`, and never decides policy. This module is the ONE place a
  context's allowed scopes become that call. Workers/connectors must route
  visibility decisions here, not re-implement them.
  """

  alias Swarm.Graph.Traverse

  @doc """
  Reachable nodes from `start_id` visible to a context with `allowed_scopes`.
  Default-deny: no allowed scopes ⇒ `[]` (no query issued).
  """
  @spec visible_neighbors(integer(), pos_integer(), [String.t()]) :: [Traverse.hit()]
  def visible_neighbors(_start_id, _max_depth, []), do: []

  def visible_neighbors(start_id, max_depth, allowed_scopes) when is_list(allowed_scopes) do
    Traverse.traverse(start_id, max_depth, scopes: allowed_scopes)
  end

  @doc "Whether a single scope is visible to a context (default-deny)."
  @spec allowed?(String.t(), [String.t()]) :: boolean()
  def allowed?(scope, allowed_scopes), do: scope in allowed_scopes
end
