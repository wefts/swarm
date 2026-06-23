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
  - **Type** must be a non-empty lowercase identifier. The type vocabulary is an
    open-but-versioned registry today (it admits any well-formed type); tightening
    it is a future schema-version bump, never silent drift.
  - **Reliability** stays in `[0, 1]`.
  """

  alias Swarm.Repo

  @schema_version 1
  @scope_rank %{"private" => 0, "group" => 1, "public" => 2}
  @scopes Map.keys(@scope_rank)
  @type_format ~r/^[a-z][a-z0-9_]*$/

  @doc "The closed scope vocabulary."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "Deny-ordering rank of a scope (`private` = 0, widest = highest), or nil."
  @spec scope_rank(String.t()) :: non_neg_integer() | nil
  def scope_rank(scope), do: Map.get(@scope_rank, scope)

  @doc "Allowed `type` format (non-empty lowercase identifier)."
  @spec type_format() :: Regex.t()
  def type_format, do: @type_format

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
    with :ok <- check_type(get(attrs, :type)),
         :ok <- check_scope(get(attrs, :scope) || "private") do
      check_reliability(get(attrs, :reliability))
    end
  end

  @doc """
  Validate an edge given its endpoints' current scopes. Enforces type, scope
  vocabulary, reliability range, that both endpoints exist (non-nil scope), and
  the ADR-5 visibility invariant (edge scope no wider than the narrowest
  endpoint). `:ok` or `{:error, reason}`.
  """
  @spec validate_edge(String.t() | nil, String.t() | nil, term(), term(), term(), term()) ::
          :ok | {:error, atom()}
  def validate_edge(src_scope, dst_scope, type, scope, reliability, provenance) do
    with :ok <- check_type(type),
         :ok <- check_scope(scope),
         :ok <- check_reliability(reliability),
         :ok <- check_provenance(provenance),
         :ok <- check_endpoint(src_scope),
         :ok <- check_endpoint(dst_scope) do
      check_visibility(scope, src_scope, dst_scope)
    end
  end

  # --- field checks ----------------------------------------------------------

  defp check_type(type) when is_binary(type) do
    if Regex.match?(@type_format, type), do: :ok, else: {:error, :invalid_type_format}
  end

  defp check_type(_), do: {:error, :missing_type}

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
  # *emission-instance* key the ADR-9 reinforcement guard dedups on; whether it
  # tracks *evidential origin* (the independence hazard) is the separate open
  # decision in ADR-9 / confidence-calculus.md, NOT settled here.
  defp check_provenance(p) when is_binary(p) do
    if String.trim(p) == "", do: {:error, :blank_provenance}, else: :ok
  end

  defp check_provenance(_), do: {:error, :blank_provenance}

  # The visibility invariant: rank(edge) <= min(rank(src), rank(dst)).
  defp check_visibility(scope, src_scope, dst_scope) do
    narrowest = min(@scope_rank[src_scope], @scope_rank[dst_scope])
    if @scope_rank[scope] <= narrowest, do: :ok, else: {:error, :scope_wider_than_endpoints}
  end

  defp get(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
