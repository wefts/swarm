defmodule Swarm.Graph.Procedure do
  @moduledoc """
  Procedure aggregation view (workspace ADR-17 §1–2). Reconstructs a "how do I X"
  procedure at READ time from ordered `has_step` claim-edges hanging off an `entity`
  node — never a stored/reified object (facts stay edges; the STEP-2 aggregation
  pattern). A step edge carries a `step_ordinal` (ADR-17 representation) and its
  evidential `origin` (ADR-13, via `edge_provenance`).

  **Load-bearing constraint (blackboard council):** a procedure may be described by
  more than one source. Steps are **grouped by `origin` FIRST, then ordered by
  `step_ordinal` within each origin** — two sources' "step 1" must never interleave
  into one broken chain. Multiple origins are returned as separate ordered variants
  (the caller/consilium judges corroboration vs conflict, like STEP-2).

  Scope-enforced on the entity, the `has_step` edge, AND each step node (no-leak);
  refuted edges (`reward < 0`) excluded, matching every other read path.

  Not here yet (follow-ups, ADR-17 §2/§3): the freshness/watermark staleness marking,
  the GC ghost-step purge, and the coverage descriptor for the tier-routing gate.
  """

  alias Swarm.Repo

  @typedoc "One source's ordered account of a procedure."
  @type variant :: %{origin: String.t(), steps: [%{ordinal: integer(), key: String.t()}]}

  @doc """
  The procedure `entity_key` describes, as per-origin ordered step variants (empty
  when the entity is absent/out-of-scope or has no ordered steps). `opts`: `:type`
  (default `"entity"`).
  """
  @spec steps(String.t(), [String.t()], keyword()) :: [variant()]
  def steps(_entity_key, [], _opts), do: []

  def steps(entity_key, scopes, opts \\ []) when is_binary(entity_key) and is_list(scopes) do
    type = Keyword.get(opts, :type, "entity")

    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT ep.origin, e.step_ordinal, dst.key
          FROM node ent
          JOIN edge e
            ON e.src = ent.id AND e.type = 'has_step' AND e.reward >= 0
           AND e.visibility_scope = ANY($2) AND e.step_ordinal IS NOT NULL
          JOIN edge_provenance ep ON ep.edge_id = e.id
          JOIN node dst ON dst.id = e.dst AND dst.scope = ANY($2)
         WHERE ent.type = $1 AND ent.key = $3 AND ent.scope = ANY($2)
         ORDER BY ep.origin, e.step_ordinal, dst.key
        """,
        [type, scopes, entity_key]
      )

    rows
    |> Enum.group_by(fn [origin, _ord, _key] -> origin end)
    |> Enum.map(fn {origin, group} ->
      %{
        origin: origin,
        steps: Enum.map(group, fn [_o, ord, key] -> %{ordinal: ord, key: key} end)
      }
    end)
    |> Enum.sort_by(& &1.origin)
  end
end
