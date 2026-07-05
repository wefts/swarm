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

  **Generation-collision belt (ADR-17 §2/§3, tier-gate council Correction 3):** a
  re-ingest can leave old+new `has_step` edges under one origin (distinct step text at
  the same ordinal) until GC — each variant carries `has_generation_collision?` so the
  tier-gate escalates rather than serve a spliced procedure even if GC is delayed.

  **Shared-step ordinal stance (residual #3, ACCEPTED 2026-07-05):** `step_ordinal` lives
  on the `has_step` EDGE, whose natural key is `(src, type, dst, scope)` — `origin` is
  provenance-level (`edge_provenance`), NOT part of the key. So if the SAME step node is
  referenced by two procedures/origins at different positions, the first-written ordinal
  wins (upsert reinforces, no-op) and the step shows under both with that one ordinal.
  Accepted, not fixed: entity-resolution rarely merges specific step-text nodes, so a true
  cross-origin shared step at divergent ordinals is a corner case. If it ever bites, the
  fix is to move the ordinal to provenance-level (per-origin) — a schema change deferred
  until there is evidence it occurs.

  Not here yet (follow-ups, ADR-17 §2/§3): the freshness/watermark staleness marking,
  the GC ghost-step purge itself, and the coverage descriptor for the tier-routing gate.
  """

  alias Swarm.Repo

  @typedoc "One source's ordered account of a procedure."
  @type variant :: %{
          origin: String.t(),
          steps: [%{ordinal: integer(), key: String.t()}],
          has_generation_collision?: boolean()
        }

  @doc """
  Procedure-CANDIDATE entity keys for a free-text query: entities that actually carry
  ≥1 in-scope, non-refuted `has_step` edge AND whose key shares a significant term with
  the query. The tier-gate probes these directly (ADR-17 #2) — generic content retrieval
  ranks a key-only procedure entity poorly, so the gate would otherwise never see it.
  Scope-enforced (edge + entity), bounded, ordered by term-overlap. `opts`: `:type`
  (default `"entity"`), `:limit` (default 8).
  """
  @spec candidates(String.t(), [String.t()], keyword()) :: [String.t()]
  def candidates(query, scopes, opts \\ [])

  def candidates(_query, [], _opts), do: []

  def candidates(query, scopes, opts) when is_binary(query) and is_list(scopes) do
    type = Keyword.get(opts, :type, "entity")
    limit = Keyword.get(opts, :limit, 8)
    terms = query_terms(query)

    if terms == [] do
      []
    else
      likes = Enum.map(terms, &("%" <> &1 <> "%"))

      %{rows: rows} =
        Repo.query!(
          """
          SELECT ent.key,
                 (SELECT count(*) FROM unnest($4::text[]) t WHERE lower(ent.key) LIKE t) AS overlap
            FROM node ent
           WHERE ent.type = $1 AND ent.scope = ANY($2)
             AND lower(ent.key) LIKE ANY($4::text[])
             AND EXISTS (
               SELECT 1 FROM edge e
                WHERE e.src = ent.id AND e.type = 'has_step' AND e.reward >= 0
                  AND e.visibility_scope = ANY($2) AND e.step_ordinal IS NOT NULL
             )
           ORDER BY overlap DESC, ent.key
           LIMIT $3
          """,
          [type, scopes, limit, likes]
        )

      Enum.map(rows, fn [key, _overlap] -> key end)
    end
  end

  # Significant query terms (lowercased, ≥3 chars, stopwords dropped) for key matching.
  @stopwords ~w(the a an of to and or for with about how what which why who when where is
                are was were do does did can could should would from your you my our this
                that these those into out get set new)
  @spec query_terms(String.t()) :: [String.t()]
  defp query_terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stopwords))
    |> Enum.uniq()
  end

  @doc """
  The procedure `entity_key` describes, as per-origin ordered step variants (empty
  when the entity is absent/out-of-scope or has no ordered steps). `opts`: `:type`
  (default `"entity"`).
  """
  @spec steps(String.t(), [String.t()], keyword()) :: [variant()]
  def steps(entity_key, scopes, opts \\ [])

  def steps(_entity_key, [], _opts), do: []

  def steps(entity_key, scopes, opts) when is_binary(entity_key) and is_list(scopes) do
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
        steps: Enum.map(group, fn [_o, ord, key] -> %{ordinal: ord, key: key} end),
        has_generation_collision?: generation_collision?(group)
      }
    end)
    |> Enum.sort_by(& &1.origin)
  end

  # A re-ingest of a changed page leaves OLD+NEW `has_step` edges under the SAME
  # origin until GC/watermark purge — so an ordinal can point at more than one
  # distinct step node, and `ORDER BY origin, step_ordinal` would splice the
  # generations (1,1,2,2,3,3). The rows are already DISTINCT on (origin, ordinal,
  # key), so within one origin any ordinal appearing on >1 row means >1 distinct
  # step text at that position — a collision. The tier-gate treats this as a HARD
  # blocker (ADR-17 §2/§3, gemini Correction 3): defence-in-depth at the aggregation
  # layer so a delayed GC can never yield a spliced served procedure.
  defp generation_collision?(group) do
    group
    |> Enum.group_by(fn [_origin, ord, _key] -> ord end)
    |> Enum.any?(fn {_ord, rows} -> length(rows) > 1 end)
  end
end
