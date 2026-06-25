defmodule Swarm.Graph.Contract do
  @moduledoc """
  The graph schema as a write-validated public contract (swarm ADR-4).

  The single point that decides whether a node/edge write is admissible to the
  shared substrate. Typed ports protect the *call* boundary; this protects the
  *data* boundary. Every write through `Swarm.Graph.Store` is validated here and
  rejected **fail-loud** on violation — nothing malformed reaches the graph that
  confidence, answers, and coordination all read.

  Rules:

  - **Scope** is a closed, ordered vocabulary: `private < group < public`.
  - **Visibility invariant (ADR-5 workspace):** an edge's scope may be no wider
    than the narrowest of its two endpoints. Enforced here, at the boundary —
    not by individual callers.
  - **Node type** is drawn from a **closed, kernel-owned vocabulary** (`types/0`),
    the identity/entity-kind axis (swarm ADR-14 §3.1). Connectors *map into* it;
    an out-of-vocabulary node type fails the write fail-loud, exactly as an
    unknown scope/kind does. This is the seam ADR-13 left open — within-type
    entity resolution is only meaningful once types are canonical. (Edge/relation
    types are a *different* axis: validated for well-formedness only, not
    membership — the relation vocabulary is connector-defined.) Tightening the
    node vocabulary is a schema-version bump, never silent drift.
  - **Reliability** stays in `[0, 1]`.
  """

  alias Swarm.Repo

  # v5 — edge-level evidential kind (workspace ADR-13, refines EOS-2): an
  # assertion carries its own `evidence_kind` (what it CONTRIBUTES), so the
  # corroboration calculus no longer mis-reads an entity source node's kind.
  # v4 added the `origin` axis + distinct-origin `seen_count`. Mirrored in
  # `graph_schema_meta` by each migration.
  @schema_version 5
  @scope_rank %{"private" => 0, "group" => 1, "public" => 2}
  @scopes Map.keys(@scope_rank)
  @type_format ~r/^[a-z][a-z0-9_]*$/
  # The closed node-type vocabulary (swarm ADR-14 §3.1) — the entity-kind/identity
  # axis. Connectors map their source units onto exactly one of these; a node with
  # any other type is rejected at the boundary (fail-loud). This is NOT the
  # relation vocabulary (edge types are validated for format only). Grows only by
  # a versioned bump, never silent drift.
  @types ~w(self agent user source article concept entity event file dir task ticket anchor)
  # Graph zones / tuple-classes (T12). `observation` = external evidence;
  # `claim` = LLM-generated (NEVER independent corroboration, ADR-3); the rest are
  # lifecycle classes. Each kind may carry its own TTL/compaction policy.
  @kinds ~w(observation claim hypothesis coordination lease derived presentation durable_fact)

  @doc "The closed scope vocabulary."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "Deny-ordering rank of a scope (`private` = 0, widest = highest), or nil."
  @spec scope_rank(String.t()) :: non_neg_integer() | nil
  def scope_rank(scope), do: Map.get(@scope_rank, scope)

  @doc "Allowed `type` format (non-empty lowercase identifier)."
  @spec type_format() :: Regex.t()
  def type_format, do: @type_format

  @doc "The closed node-type vocabulary (entity-kind/identity axis, swarm ADR-14 §3.1)."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The closed node-kind vocabulary (graph zones / tuple-classes, T12)."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The compiled-in graph schema version (mirrors the `graph_schema_meta` stamp)."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "The DB-stamped graph schema version (queryable; set/bumped by migration)."
  @spec stamped_version() :: integer()
  def stamped_version do
    %{rows: [[v]]} = Repo.query!("SELECT version FROM graph_schema_meta WHERE id = 1")
    v
  end

  @doc """
  Validate a node's contract fields. `:ok` or `{:error, reason}`. Absent `scope`
  defaults to `private`; absent `reliability` defers to the schema default.
  """
  @spec validate_node(map()) :: :ok | {:error, atom()}
  def validate_node(attrs) do
    with :ok <- check_node_type(get(attrs, :type)),
         :ok <- check_scope(get(attrs, :scope) || "private") do
      check_reliability(get(attrs, :reliability))
    end
  end

  @doc """
  Validate an edge given its endpoints' current scopes. Enforces type, scope
  vocabulary, reliability range, that both endpoints exist (non-nil scope), the
  ADR-5 visibility invariant (edge scope no wider than the narrowest endpoint),
  that both the emission-instance `provenance` and the evidential `origin`
  (workspace ADR-13) keys are present, and that `evidence_kind` is in the kind
  vocabulary. `:ok` or `{:error, reason}`.
  """
  @spec validate_edge(
          String.t() | nil,
          String.t() | nil,
          term(),
          term(),
          term(),
          term(),
          term(),
          term()
        ) :: :ok | {:error, atom()}
  def validate_edge(
        src_scope,
        dst_scope,
        type,
        scope,
        reliability,
        provenance,
        origin,
        evidence_kind
      ) do
    with :ok <- check_type(type),
         :ok <- check_scope(scope),
         :ok <- check_reliability(reliability),
         :ok <- check_provenance(provenance),
         :ok <- check_origin(origin),
         :ok <- check_evidence_kind(evidence_kind),
         :ok <- check_endpoint(src_scope),
         :ok <- check_endpoint(dst_scope) do
      check_visibility(scope, src_scope, dst_scope)
    end
  end

  # --- field checks ----------------------------------------------------------

  # Edge/relation type: well-formedness only (the relation vocabulary is
  # connector-defined, not a closed kernel set).
  defp check_type(type) when is_binary(type) do
    if Regex.match?(@type_format, type), do: :ok, else: {:error, :invalid_type_format}
  end

  defp check_type(_), do: {:error, :missing_type}

  # Node type: well-formed AND a member of the closed kernel vocabulary (§3.1).
  defp check_node_type(type) when is_binary(type) do
    cond do
      not Regex.match?(@type_format, type) -> {:error, :invalid_type_format}
      type not in @types -> {:error, :unknown_type}
      true -> :ok
    end
  end

  defp check_node_type(_), do: {:error, :missing_type}

  defp check_scope(scope) when is_binary(scope) do
    if scope in @scopes, do: :ok, else: {:error, :unknown_scope}
  end

  defp check_scope(_), do: {:error, :unknown_scope}

  defp check_reliability(nil), do: :ok

  defp check_reliability(r) when is_number(r) do
    if r >= 0.0 and r <= 1.0, do: :ok, else: {:error, :reliability_out_of_range}
  end

  defp check_reliability(_), do: {:error, :reliability_out_of_range}

  defp check_endpoint(scope) when is_binary(scope), do: :ok
  defp check_endpoint(_), do: {:error, :unknown_endpoint}

  # Shape only: a provenance key must be present and non-blank. This is the
  # *emission-instance* key the ADR-9 reinforcement guard dedups on (one event
  # never counts twice); evidential independence is the `origin` axis below.
  defp check_provenance(p) when is_binary(p) do
    if String.trim(p) == "", do: {:error, :blank_provenance}, else: :ok
  end

  defp check_provenance(_), do: {:error, :blank_provenance}

  # Shape only: an origin key must be present and non-blank (workspace ADR-13).
  # `origin` is the *evidential source identity* — derived by the connector from
  # content/source so re-emitting the same fact reuses the same key — that
  # corroboration and reinforcement count distinct instances of. `Store.add_edge`
  # defaults it to the provenance key when a caller does not supply one (every
  # event its own origin = pre-v4 behaviour), so it is always present here.
  defp check_origin(o) when is_binary(o) do
    if String.trim(o) == "", do: {:error, :blank_origin}, else: :ok
  end

  defp check_origin(_), do: {:error, :blank_origin}

  # The assertion's evidential kind (workspace ADR-13): what this edge CONTRIBUTES
  # to corroboration — `observation` (external) vs `claim`/`derived` (generated),
  # drawn from the same closed kind vocabulary as `node.kind`. Mis-typed kinds are
  # rejected fail-loud (the DB CHECK is defense-in-depth behind this).
  defp check_evidence_kind(k) when is_binary(k) do
    if k in @kinds, do: :ok, else: {:error, :unknown_evidence_kind}
  end

  defp check_evidence_kind(_), do: {:error, :unknown_evidence_kind}

  # The visibility invariant: rank(edge) <= min(rank(src), rank(dst)).
  defp check_visibility(scope, src_scope, dst_scope) do
    narrowest = min(@scope_rank[src_scope], @scope_rank[dst_scope])
    if @scope_rank[scope] <= narrowest, do: :ok, else: {:error, :scope_wider_than_endpoints}
  end

  defp get(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
