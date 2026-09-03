defmodule Swarm.Graph.Contract do
  @moduledoc """
  The graph schema as a write-validated public contract (swarm ADR-4).

  The single point that decides whether a node/edge write is admissible to the
  shared substrate. Typed ports protect the *call* boundary; this protects the
  *data* boundary. Every write through `Swarm.Graph.Store` is validated here and
  rejected **fail-loud** on violation — nothing malformed reaches the graph that
  confidence, answers, and coordination all read.

  Rules:

  - **Scope** is a lattice: `private` is bottom, `public` is top, and each
    `src:<source_uuid>` is an incomparable mid-band tag (workspace ADR-20: the
    stable Source id is the security coordinate; human labels such as `wiki` are
    never scope keys; the legacy `group` scope is retired).
  - **Visibility invariant (ADR-5 workspace):** an edge's scope must be less
    than or equal to the greatest lower bound of its endpoints. Enforced here,
    at the boundary — not by individual callers.
  - **Node type** is drawn from a **closed, kernel-owned vocabulary** (`types/0`),
    the identity/entity-kind axis (swarm ADR-14 §3.1). Connectors *map into* it;
    an out-of-vocabulary node type fails the write fail-loud, exactly as an
    unknown scope/kind does. This is the seam ADR-13 left open — within-type
    entity resolution is only meaningful once types are canonical. Edge/relation
    names remain an open connector-defined vocabulary, but governed structural
    relations from `Swarm.WorldMap.Domain` also enforce subject/object endpoint
    kinds at write time. Tightening the node vocabulary is a schema-version bump,
    never silent drift.
  - **Reliability** stays in `[0, 1]`.
  """

  alias Swarm.Repo
  alias Swarm.WorldMap.Domain

  @type endpoint_meta :: %{
          optional(:id) => integer(),
          optional(:scope) => String.t() | nil,
          optional(:type) => String.t() | nil,
          optional(:key) => String.t() | nil
        }

  # v12 — network address semantics: `net:address:*` / `net:subnet:*` nodes gain typed
  # PostgreSQL `inet` / `cidr` columns plus deterministic address-class labels so containment and
  # public/private address asks are data operations, not prose/model guesses.
  # v11 — project access (workspace ADR-20): the source scope key becomes the STABLE source id
  # `src:<source_uuid>` (a `source` row owned by a `project`); `src:<name>` labels and the
  # transitional `group` scope are migrated away and the CHECK constraints tightened to
  # {private, public, src:<uuid>}. Effective scopes derive from Project membership (Swarm.Projects).
  # v10 — per-source scope (ADR-18): scope value space {private,group,public} → {private,public,
  # src:*}; the `group` scope is migrated to per-source `src:<name>` (transitional CHECK still admits
  # `group`); scope ordering becomes the lattice (private=⊥, public=⊤, src:* incomparable mid-band).
  # v9 — node_do_not_merge (master-plan S4): a negative identity assertion so ER/merge never
  # collapse two DISTINCT entities.
  # v8 — edge_provenance.lineage (master-plan S1): corroboration counts distinct upstream lineage,
  # not origin labels (mechanism landed inert — lineage defaults to origin; granularity policy TBD).
  # v7 added edge_provenance.source_node_id (ghost-purge). v6 …
  # v5 — edge-level evidential kind (workspace ADR-13, refines EOS-2): an
  # assertion carries its own `evidence_kind` (what it CONTRIBUTES), so the
  # corroboration calculus no longer mis-reads an entity source node's kind.
  # v4 added the `origin` axis + distinct-origin `seen_count`. Mirrored in
  # `graph_schema_meta` by each migration.
  @schema_version 12
  @scopes ~w(private public)
  # A source scope is `src:` + the source's lowercase hyphenated UUID — never a label.
  @uuid_re "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @src_format ~r/^src:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  @type_format ~r/^[a-z][a-z0-9_]*$/
  # The closed node-type vocabulary (swarm ADR-14 §3.1) — the entity-kind/identity
  # axis. Connectors map their source units onto exactly one of these; a node with
  # any other type is rejected at the boundary (fail-loud). This is NOT the
  # relation vocabulary (edge types are validated for format only). Grows only by
  # a versioned bump, never silent drift.
  #
  # `user` is RESERVED for the person-as-data projection (`Swarm.Person`, ADR-16)
  # and is pinned to `private` scope (person-scope-leak-guard). Connectors and
  # enrichers map corpus-mentioned people to `entity` (or `agent` for actors),
  # never `user` — a wider `user` write fails loud.
  @types ~w(self agent user source article concept entity event file dir task ticket anchor step)
  # Graph zones / tuple-classes (T12). `observation` = external evidence;
  # `claim` = LLM-generated (NEVER independent corroboration, ADR-3); the rest are
  # lifecycle classes. Each kind may carry its own TTL/compaction policy.
  @kinds ~w(observation claim hypothesis coordination lease derived presentation durable_fact)

  @doc "The closed base scope vocabulary (`private`, `public`); source scopes are `src:<uuid>`."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  True if a scope is admissible: the closed base vocab OR a well-formed source scope
  (`src:` + a lowercase hyphenated UUID). A human label (`src:wiki`) is NOT admissible
  (workspace ADR-20 D2 — labels are never security keys).
  """
  @spec valid_scope?(String.t()) :: boolean()
  def valid_scope?(scope) when is_binary(scope) do
    scope in @scopes or scope =~ @src_format
  end

  def valid_scope?(_), do: false

  @doc "True iff `scope` is a well-formed source scope (`src:<uuid>`)."
  @spec source_scope?(term()) :: boolean()
  def source_scope?(scope) when is_binary(scope), do: scope =~ @src_format
  def source_scope?(_), do: false

  @doc "The source scope for a source id: `\"src:\" <> uuid` (raises on a malformed uuid)."
  @spec source_scope(String.t()) :: String.t()
  def source_scope(source_id) when is_binary(source_id) do
    scope = "src:" <> String.downcase(source_id)

    if scope =~ @src_format,
      do: scope,
      else: raise(ArgumentError, "not a source uuid: #{source_id}")
  end

  @doc "The source id behind a source scope, or `nil` for a non-source scope."
  @spec scope_source_id(term()) :: String.t() | nil
  def scope_source_id("src:" <> id = scope) when is_binary(scope) do
    if scope =~ @src_format, do: id, else: nil
  end

  def scope_source_id(_), do: nil

  @doc "The SQL regex (POSIX) a source scope must match — for CHECK constraints and migrations."
  @spec source_scope_sql_regex() :: String.t()
  def source_scope_sql_regex, do: "^src:" <> @uuid_re <> "$"

  @doc """
  True for a DERIVED-fact origin (`enrich:*` / `synonymy*`): such a fact inherits its anchor
  node's scope — it never mints or widens one (operator 2026-07-08; ADR-20 D12). Content origins
  (`wiki:*`, `confluence:*`, `ldap:*`, `iac:*`, …) are labels only: their scope is whatever
  registered Source the connector was told to write under (`Swarm.Projects.scope!/1`).
  """
  @spec derived_origin?(term()) :: boolean()
  def derived_origin?(origin) when is_binary(origin) do
    (origin |> String.split(":", parts: 2) |> hd()) in ~w(enrich synonymy)
  end

  def derived_origin?(_), do: false

  @doc """
  Lattice partial order: `private` ≤ everything, everything ≤ `public`, else only equal scopes are ≤.
  """
  @spec lattice_leq(String.t(), String.t()) :: boolean()
  def lattice_leq(a, b) when is_binary(a) and is_binary(b) do
    a == b or a == "private" or b == "public"
  end

  @doc """
  Greatest lower bound in the scope lattice — the write-time clamp for an edge's endpoints.
  Two DIFFERENT source scopes have GLB `private` (the accepted cross-source-edge cost, ADR-18 F3).
  """
  @spec glb(String.t(), String.t()) :: String.t()
  def glb(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a == b -> a
      a == "private" or b == "private" -> "private"
      a == "public" -> b
      b == "public" -> a
      true -> "private"
    end
  end

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

  Person pin (ADR-16 person-scope-leak-guard): a `user`-typed node is a person
  subject and is admissible **only at `private` scope** — the graph has no owner
  axis, so `private` IS the per-user privacy mechanism; a wider person node would
  surface chat-derived facts to scoped corpus reads. Enforced here at the data
  boundary, not by callers (widening a person is an item-3 owner-axis design,
  not a write anyone may perform today).
  """
  @spec validate_node(map()) :: :ok | {:error, atom()}
  def validate_node(attrs) do
    scope = get(attrs, :scope) || "private"

    with :ok <- check_node_type(get(attrs, :type)),
         :ok <- check_scope(scope),
         :ok <- check_person_scope(get(attrs, :type), scope) do
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

  @doc """
  Validate governed relation endpoint kinds against `Swarm.WorldMap.Domain`.

  Unknown relation names remain connector-defined and are not closed by this
  check. For governed relations, endpoint kinds are inferred from existing node
  metadata without relabeling or mutating the graph.
  """
  @spec validate_relation_endpoints(term(), endpoint_meta() | nil, endpoint_meta() | nil) ::
          :ok | {:error, term()}
  def validate_relation_endpoints(type, src_endpoint, dst_endpoint) do
    case Domain.structural_relation(type) do
      nil ->
        :ok

      relation ->
        dst_kinds = inferred_kinds(dst_endpoint)
        src_kinds = inferred_kinds(src_endpoint, relation, dst_kinds)

        if admissible_inferred_kinds?(relation, src_kinds, dst_kinds) do
          :ok
        else
          {:error,
           {:relation_endpoint_kinds_mismatch,
            %{
              relation: relation.key,
              subject_kinds: src_kinds,
              object_kinds: dst_kinds,
              expected_subject_kinds: relation.subject_kinds,
              expected_object_kinds: relation.object_kinds
            }}}
        end
    end
  end

  # --- field checks ----------------------------------------------------------

  # Relation names stay connector-defined and open. Governed structural names get
  # endpoint-kind validation separately in validate_relation_endpoints/3.
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
    if valid_scope?(scope), do: :ok, else: {:error, :unknown_scope}
  end

  defp check_scope(_), do: {:error, :unknown_scope}

  # The person pin: `user`-typed nodes only at `private` (see validate_node/1 doc).
  defp check_person_scope("user", scope) when scope != "private",
    do: {:error, :person_scope_not_private}

  defp check_person_scope(_, _), do: :ok

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

  # The visibility invariant: edge scope <= GLB(src scope, dst scope).
  defp check_visibility(scope, src_scope, dst_scope) do
    if lattice_leq(scope, glb(src_scope, dst_scope)),
      do: :ok,
      else: {:error, :scope_wider_than_endpoints}
  end

  defp inferred_kinds(nil), do: []

  defp inferred_kinds(endpoint) when is_map(endpoint) do
    endpoint
    |> base_kinds()
    |> add_article_page_alias(endpoint)
    |> add_entity_namespace_kind(endpoint)
    |> add_entity_key_shape_kind(endpoint)
    |> add_concept_kinds(endpoint)
    |> Enum.uniq()
  end

  defp inferred_kinds(endpoint, relation, peer_kinds) do
    endpoint
    |> inferred_kinds()
    |> add_relation_context_kind(endpoint, relation, peer_kinds)
  end

  @spec base_kinds(endpoint_meta()) :: [String.t()]
  defp base_kinds(%{type: type}) when is_binary(type), do: [type]
  defp base_kinds(_), do: []

  @spec add_article_page_alias([String.t()], endpoint_meta()) :: [String.t()]
  defp add_article_page_alias(kinds, %{type: "article"}), do: ["page" | kinds]
  defp add_article_page_alias(kinds, _), do: kinds

  @spec add_entity_namespace_kind([String.t()], endpoint_meta()) :: [String.t()]
  defp add_entity_namespace_kind(kinds, %{type: "entity", key: key}) when is_binary(key) do
    case String.split(key, ":", parts: 3) do
      [namespace, kind, _] when namespace in ["net", "who"] and kind != "" ->
        [kind, "entity" | kinds]

      _ ->
        kinds
    end
  end

  defp add_entity_namespace_kind(kinds, _), do: kinds

  @spec add_entity_key_shape_kind([String.t()], endpoint_meta()) :: [String.t()]
  defp add_entity_key_shape_kind(kinds, %{type: "entity", key: key}) when is_binary(key) do
    cond do
      bare_ip?(key) ->
        ["address" | kinds]

      bare_fqdn?(key) ->
        ["host" | kinds]

      true ->
        kinds
    end
  end

  defp add_entity_key_shape_kind(kinds, _), do: kinds

  defp add_relation_context_kind(
         kinds,
         %{type: "entity"},
         %{key: "has_step"},
         peer_kinds
       ) do
    if "step" in peer_kinds, do: Enum.uniq(["procedure" | kinds]), else: kinds
  end

  defp add_relation_context_kind(kinds, _endpoint, _relation, _peer_kinds), do: kinds

  @spec add_concept_kinds([String.t()], endpoint_meta()) :: [String.t()]
  defp add_concept_kinds(kinds, %{type: "concept", key: key}) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      ["concept", kind] when kind != "" -> [kind, "kind", "concept" | kinds]
      _ -> ["kind", "concept" | kinds]
    end
  end

  defp add_concept_kinds(kinds, %{type: "concept"}), do: ["kind", "concept" | kinds]

  defp add_concept_kinds(kinds, %{key: "concept:" <> kind}) when kind != "",
    do: [kind, "concept" | kinds]

  defp add_concept_kinds(kinds, _), do: kinds

  defp admissible_inferred_kinds?(
         %{subject_kinds: [:same_kind], object_kinds: [:same_kind]},
         src_kinds,
         dst_kinds
       ) do
    src_comparable = same_kind_comparable_kinds(src_kinds)
    dst_comparable = same_kind_comparable_kinds(dst_kinds)

    overlaps?(src_comparable, dst_comparable)
  end

  defp admissible_inferred_kinds?(relation, src_kinds, dst_kinds) do
    overlaps?(src_kinds, relation.subject_kinds) and
      overlaps?(dst_kinds, relation.object_kinds)
  end

  defp same_kind_comparable_kinds(kinds) do
    specific = Enum.reject(kinds, &(&1 == "entity"))
    if specific == [], do: kinds, else: specific
  end

  defp overlaps?(left, right) do
    Enum.any?(left, &(&1 in right))
  end

  @spec bare_ip?(String.t()) :: boolean()
  defp bare_ip?(key) do
    case :inet.parse_address(String.to_charlist(key)) do
      {:ok, _addr} -> true
      {:error, _} -> false
    end
  end

  @spec bare_fqdn?(String.t()) :: boolean()
  defp bare_fqdn?(key) do
    Regex.match?(
      ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/i,
      key
    )
  end

  defp get(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
