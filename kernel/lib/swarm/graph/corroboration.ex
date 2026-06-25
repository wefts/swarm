defmodule Swarm.Graph.Corroboration do
  @moduledoc """
  Node-local evidential corroboration (workspace ADR-13) — the production caller
  of `Swarm.Graph.Confidence.combine_typed/1`.

  Distinct from two neighbours it must not be confused with:

  - **Traversal PATH confidence** (`Swarm.Graph.Traverse`): a single-source walk
    keeps `max(path_confidence)` because all paths share the start ancestor;
    combining paths by noisy-OR is the large-scale path-independence problem that
    ADR-3 explicitly **defers**. Corroboration never combines paths, so it does
    not touch that problem.
  - **A node's intrinsic reliability** (`node.reliability`, `r_0·w_source`): the
    trust of the node itself, not how independently it is asserted.

  Corroboration answers: *how strongly is this node asserted by INDEPENDENT typed
  evidence?* It gathers the **evidential** edges directly asserting the node
  (incoming, not refuted — `reward ≥ 0`, excluding structural/navigation relations
  like `links_to`/`child_of` which are topology, not evidence), reduces them to
  **one typed contribution per distinct
  evidential `origin`** (the strongest assertion within that origin, tagged by the
  edge's `evidence_kind` — what the assertion CONTRIBUTES, not what its source node
  *is*; ADR-13 refines EOS-2), then applies `combine_typed/1`:

  - co-located LLM-generated assertions (`claim`/`hypothesis`/`derived`) collapse
    into one group — a hallucination cannot corroborate itself by repetition;
  - each distinct EXTERNAL origin (`observation`/`durable_fact`) is independent,
    composed by noisy-OR.

  The origin-dedup is load-bearing: N derivatives of one source collapse to one
  contribution, so the distinct-origin `seen_count` never leaks back in as "more
  rows ⇒ more belief" (the hazard ADR-13 exists to prevent).

  Performance: one indexed query over incoming edges (`edge.dst` index) joined to
  their provenance rows; bounded by the asserted nodes' in-degree, never a graph
  scan. Aggregation is per-node app-side over that bounded set.
  """

  alias Swarm.Config
  alias Swarm.Graph.Confidence
  alias Swarm.Repo

  # Structural / navigation relations are NOT evidential assertions: a wiki link or
  # a parent-child containment says "A points at B", not "an independent source
  # attests B". Counting them would conflate topology with evidence — link
  # popularity becoming belief strength (decorrelated council, 2026-06-25). Only
  # evidential relations (enrichment's claim/observation assertions) corroborate;
  # this denylist is excluded. The relation vocabulary is connector-defined (open),
  # so corroboration excludes known-structural relations rather than allow-listing.
  @structural_relations ~w(links_to child_of)

  @doc "Relations excluded from corroboration (structural/navigation, not evidence)."
  @spec structural_relations() :: [String.t()]
  def structural_relations, do: @structural_relations

  @doc """
  Corroboration of a single node. `:scopes` (a list) prunes assertions to edges
  and asserting nodes visible at those scopes. Returns `0.0` when the node has no
  (visible, non-refuted) typed assertions.
  """
  @spec node(integer(), keyword()) :: float()
  def node(node_id, opts \\ []) when is_integer(node_id) do
    [node_id] |> for_nodes(opts) |> Map.get(node_id, 0.0)
  end

  @doc """
  Batched corroboration for many nodes → `%{node_id => confidence}` in one query.
  Nodes with no (visible, non-refuted) typed assertions are **absent** from the
  map, so a caller can fall back to the node's intrinsic reliability.
  """
  @spec for_nodes([integer()], keyword()) :: %{integer() => float()}
  def for_nodes([], _opts), do: %{}

  def for_nodes(node_ids, opts) when is_list(node_ids) do
    lambda = Config.decay_lambda()
    {sql, params} = query(node_ids, lambda, Keyword.get(opts, :scopes))

    Repo.query!(sql, params).rows
    # rows: [dst_id, origin, kind, decayed_conf]
    |> Enum.group_by(fn [dst | _] -> dst end, fn [_dst, origin, kind, conf] ->
      {origin, kind, conf}
    end)
    |> Map.new(fn {dst, assertions} -> {dst, corroborate(assertions)} end)
  end

  # One typed contribution per distinct origin: the strongest assertion within the
  # origin (max effective confidence), tagged by THAT assertion's kind; then
  # combine_typed across origins. Dedup-by-origin happens BEFORE combine_typed so
  # N derivatives of one source can never count as N independent witnesses.
  @spec corroborate([{String.t(), String.t(), float()}]) :: float()
  defp corroborate(assertions) do
    assertions
    |> Enum.group_by(fn {origin, _kind, _conf} -> origin end)
    |> Enum.map(fn {_origin, group} ->
      {_origin, kind, conf} = Enum.max_by(group, fn {_o, _k, c} -> c end)
      {conf, kind}
    end)
    |> Confidence.combine_typed()
  end

  # Incoming assertions of each node: the edge's evidence_kind (what the assertion
  # CONTRIBUTES — ADR-13/EW-1, not the source node's kind) and decayed reliability,
  # one row per distinct (edge, provenance) carrying its origin. Decay mirrors
  # `Swarm.Graph.Traverse` (per-hop `exp(-λ·age_days)`).
  @spec query([integer()], float(), [String.t()] | nil) :: {String.t(), list()}
  defp query(node_ids, lambda, nil) do
    {"""
     SELECT e.dst, coalesce(ep.origin, ep.provenance), e.evidence_kind,
            e.reliability * exp(-$2::float8 * EXTRACT(EPOCH FROM (now() - e.last_seen)) / 86400.0)
       FROM edge e
       JOIN edge_provenance ep ON ep.edge_id = e.id
      WHERE e.dst = ANY($1) AND e.reward >= 0
        AND e.type <> ALL($3::text[])
     """, [node_ids, lambda, @structural_relations]}
  end

  defp query(node_ids, lambda, scopes) when is_list(scopes) do
    # Visibility is filtered on BOTH the edge scope AND the source node scope
    # (defense-in-depth): the edge-scope ≤ narrowest-endpoint invariant is only
    # write-enforced (ADR-4 names durability gaps), so a read that must not leak
    # cannot rely on it alone (council, codex). evidence_kind still comes from the
    # edge — visibility and kind are separate concerns.
    {"""
     SELECT e.dst, coalesce(ep.origin, ep.provenance), e.evidence_kind,
            e.reliability * exp(-$2::float8 * EXTRACT(EPOCH FROM (now() - e.last_seen)) / 86400.0)
       FROM edge e
       JOIN node n ON n.id = e.src AND n.scope = ANY($3::text[])
       JOIN edge_provenance ep ON ep.edge_id = e.id
      WHERE e.dst = ANY($1) AND e.reward >= 0
        AND e.visibility_scope = ANY($3::text[])
        AND e.type <> ALL($4::text[])
     """, [node_ids, lambda, scopes, @structural_relations]}
  end
end
