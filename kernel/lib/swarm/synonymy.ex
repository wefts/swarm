defmodule Swarm.Synonymy do
  @moduledoc """
  Concept/vocabulary synonymy (workspace ADR-17 substrate; blackboard council
  2026-07-04). Folds surface forms of ONE concept (e.g. `SSP` == `Self Service
  Password`, `k8s` == `Kubernetes`) so a query in the user's words reaches the
  corpus's words.

  **Distinct from entity-resolution (council, both families):** synonymy is NOT an
  ER identity-merge. A synonym is a **reversible `synonym_of` claim-edge** between two
  distinct nodes — never a destructive `merge_nodes` collapse. That keeps it:

    * reversible (drop the edge — matters for staging kill-and-rebuild + rollback);
    * polysemy-safe (a form may carry `synonym_of` to more than one canonical — e.g.
      `SSP` in two senses — resolved by scope/context, never globally collapsed);
    * canon-clean (facts stay edges; no reification).

  This module is slice 1: the **algorithmic acronym/numeronym signal** (the cheapest,
  strongest independent gate — no LLM, no vector), the reversible edge, and the
  query-time form resolver. The vector + definitional-apposition + shared-neighbor
  candidate proposer, the strict LLM confirm, and the sibling/polysemy guards are the
  next slices (see `board/doing/concept-synonymy-resolution.md`).
  """

  alias Swarm.Graph.Store
  alias Swarm.ML.Generation
  alias Swarm.Repo

  @relation "synonym_of"
  # Contrastive relation: two forms explicitly NOT the same (siblings, e.g. "React"
  # vs "Vue"). An edge of this type between a candidate pair auto-REJECTS the synonym
  # proposal before any confirm (council gemini — the structural sibling shield).
  @sibling "sibling_of"

  @confirm_system ~s(You decide whether two surface forms are PERFECTLY INTERCHANGEABLE ) <>
                    ~s(synonyms for the SAME concept in a technical knowledge base ) <>
                    ~s(\(e.g. an acronym and its expansion\). REJECT if they are merely ) <>
                    ~s(related, siblings, one a subset of the other, or different senses. ) <>
                    ~s(Answer ONLY JSON: {"same": true} or {"same": false}. Any doubt => false.)

  @doc """
  Is `short` an acronym (initialism) or numeronym of `long`? The algorithmic
  independent signal — structural only, so it holds for BOTH senses of a polysemous
  acronym (disambiguation is scope + the LLM confirm's job, not this function's).

    * initialism: the first letters of `long`'s words spell `short` (`SSP` ⇐
      "Self Service Password");
    * numeronym: `first-letter + <count of inner letters> + last-letter`
      (`k8s` ⇐ "Kubernetes", `i18n` ⇐ "internationalization").
  """
  @spec acronym?(String.t(), String.t()) :: boolean()
  def acronym?(short, long) when is_binary(short) and is_binary(long) do
    s = norm(short)
    words = long |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    s != "" and words != [] and (initialism?(s, words) or numeronym?(s, words))
  end

  def acronym?(_, _), do: false

  @doc """
  Link `alias_key` as a synonym of `canonical_key` (both existing nodes of the given
  `type`, default `concept`) via a reversible `synonym_of` edge. The edge scope is
  **derived** from the (equal) endpoint scope — a cross-scope pair is refused
  (`{:error, :cross_scope}`, mirror ER); a self-link is refused (`{:error, :self_link}`).
  `opts`: `:type` (default `"concept"`), `:origin` (default `"synonymy"`). (`:scope` is
  NOT an option — the edge can never diverge from its endpoints, else it would leak.)
  """
  @spec link(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:error, :cross_scope | :self_link | :sibling_conflict | :unknown_node | term()}
  def link(alias_key, canonical_key, opts \\ []) do
    type = Keyword.get(opts, :type, "concept")
    origin = Keyword.get(opts, :origin, "synonymy")

    with :ok <- distinct(alias_key, canonical_key),
         {:ok, a} <- node_id(type, alias_key),
         {:ok, c} <- node_id(type, canonical_key),
         {:ok, scope} <- shared_scope(a, c),
         :ok <- no_sibling_conflict(a, c, scope) do
      # Canonical ORIENTATION by node id (src=min, dst=max) so `A,B` and `B,A`
      # collapse to ONE natural-key edge — no duplicate, and `unlink` finds it
      # regardless of argument order (code review). Edge scope = the shared endpoint
      # scope (never a caller default that could diverge from the nodes → no-leak).
      {src, dst} = if a <= c, do: {a, c}, else: {c, a}

      Store.add_edge(src, dst, @relation, origin,
        scope: scope,
        origin: origin,
        evidence_kind: "derived"
      )
    end
  end

  @doc "Drop the `synonym_of` link between the two forms, either orientation (reversibility / rollback). Idempotent."
  @spec unlink(String.t(), String.t(), keyword()) :: :ok
  def unlink(alias_key, canonical_key, opts \\ []) do
    type = Keyword.get(opts, :type, "concept")

    # Delete the edge between the two keyed nodes in BOTH orientations. Edge scope
    # equals the (single) node scope, so matching the endpoints is scope-correct
    # without a scope arg (which the old signature ignored — code review).
    Repo.query!(
      """
      DELETE FROM edge e
       USING node x, node y
       WHERE e.type = $1 AND x.type = $2 AND y.type = $2
         AND x.key = $3 AND y.key = $4
         AND ((e.src = x.id AND e.dst = y.id) OR (e.src = y.id AND e.dst = x.id))
      """,
      [@relation, type, alias_key, canonical_key]
    )

    :ok
  end

  @doc """
  All surface forms `key` addresses, within `scopes` — the **transitive closure** of
  the `synonym_of` relation from `key` (so `SSP → Self Service Password ← SS Password`
  resolves the full set from ANY member, not just immediate neighbours — code review).
  Scope-enforced on the edge AND every hop's endpoints, and **type-pure** (only nodes
  of the same `type` — a malformed cross-type edge can't leak an article key through
  concept expansion). An unlinked form resolves to just `[key]`. Depth-bounded (a
  synonym set is tiny; the bound is a runaway guard). This is the query-time expansion
  the retrieval/aggregation path will consult (slice 2).
  """
  @spec forms(String.t(), [String.t()], keyword()) :: [String.t()]
  def forms(key, scopes, opts \\ []) do
    type = Keyword.get(opts, :type, "concept")
    max_depth = Keyword.get(opts, :max_depth, 6)

    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE comp(id, depth) AS (
          SELECT n.id, 0
            FROM node n
           WHERE n.type = $2 AND n.key = $4 AND n.scope = ANY($3)
          UNION
          SELECT other.id, comp.depth + 1
            FROM comp
            JOIN edge e
              ON e.type = $1 AND e.visibility_scope = ANY($3) AND e.reward >= 0
             AND (e.src = comp.id OR e.dst = comp.id)
            JOIN node other
              ON other.id = CASE WHEN e.src = comp.id THEN e.dst ELSE e.src END
             AND other.type = $2 AND other.scope = ANY($3)
           WHERE comp.depth < $5
        )
        SELECT DISTINCT n.key FROM comp JOIN node n ON n.id = comp.id
        """,
        [@relation, type, scopes, key, max_depth]
      )

    case List.flatten(rows) do
      [] -> [key]
      keys -> Enum.uniq(keys)
    end
  end

  @doc """
  Query-time expansion (slice 2): augment `query` with the synonym surface forms of
  any concept it names, so a query in the USER's words also matches the CORPUS's words
  (e.g. "reset my SSP" also matches "Self Service Password" chunks). A query token that
  case-insensitively equals a `concept` node key contributes that concept's whole
  `synonym_of` closure (scope-enforced, type-pure, depth-bounded). Forms already
  present in the query (case-insensitive) are not re-added. Returns the augmented
  string (the original unchanged when nothing expands) — feed it to the LEXICAL/title
  arm only; the dense arm embeds the original NL query.
  """
  @spec expand_query(String.t(), [String.t()], keyword()) :: String.t()
  def expand_query(query, scopes, opts \\ [])
  def expand_query(query, [], _opts), do: query

  def expand_query(query, scopes, opts) when is_binary(query) do
    type = Keyword.get(opts, :type, "concept")
    max_depth = Keyword.get(opts, :max_depth, 6)
    toks = query_tokens(query)

    if toks == [] do
      query
    else
      %{rows: rows} =
        Repo.query!(
          """
          WITH RECURSIVE seeds(id) AS (
            SELECT n.id FROM node n
             WHERE n.type = $1 AND n.scope = ANY($2) AND lower(n.key) = ANY($3)
          ),
          comp(id, depth) AS (
            SELECT id, 0 FROM seeds
            UNION
            SELECT other.id, comp.depth + 1
              FROM comp
              JOIN edge e
                ON e.type = 'synonym_of' AND e.visibility_scope = ANY($2) AND e.reward >= 0
               AND (e.src = comp.id OR e.dst = comp.id)
              JOIN node other
                ON other.id = CASE WHEN e.src = comp.id THEN e.dst ELSE e.src END
               AND other.type = $1 AND other.scope = ANY($2)
             WHERE comp.depth < $4
          )
          SELECT DISTINCT n.key FROM comp JOIN node n ON n.id = comp.id
          """,
          [type, scopes, toks, max_depth]
        )

      present = MapSet.new(toks)

      # A form is already present if ALL its tokens are in the query (handles a
      # multi-word form like "Self Service Password" whose tokens are all present —
      # avoids re-adding + overweighting it in the raw bm25 arm; code review).
      added =
        rows
        |> List.flatten()
        |> Enum.reject(fn k -> MapSet.subset?(MapSet.new(query_tokens(k)), present) end)

      if added == [], do: query, else: query <> " " <> Enum.join(added, " ")
    end
  end

  def expand_query(query, _scopes, _opts), do: query

  # Distinct lowercased content tokens of a query (len >= 2), for concept-key matching.
  @spec query_tokens(String.t()) :: [String.t()]
  defp query_tokens(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
  end

  @typedoc "A proposed synonym pair: short (alias) form, long (canonical) form, shared scope."
  @type candidate :: %{alias_key: String.t(), canonical_key: String.t(), scope: String.t()}

  @doc """
  Propose synonym candidates via the ALGORITHMIC acronym signal (slice 3): pairs of
  existing `concept` nodes where one key is an acronym/numeronym of the other
  (`acronym?/2`), SAME scope, NOT already `synonym_of`-linked, and NOT blocked by a
  `sibling_of` contrastive edge. High-precision structural signal — no LLM, no vector.
  The long form is the canonical, the short the alias. `opts`: `:scan` (max concept
  nodes examined, default 2000), `:limit` (max candidates, default 50), `:type`.
  The vector + definitional-apposition + shared-neighbor candidate paths are slice 3b
  (carded) — additive signals for synonyms that share no acronym relation.
  """
  @spec propose_acronyms(keyword()) :: [candidate()]
  def propose_acronyms(opts \\ []) do
    type = Keyword.get(opts, :type, "concept")
    scan = Keyword.get(opts, :scan, 2000)
    limit = Keyword.get(opts, :limit, 50)

    nodes =
      Repo.query!(
        "SELECT id, key, scope FROM node WHERE type = $1 ORDER BY id LIMIT $2",
        [type, scan]
      ).rows
      |> Enum.map(fn [id, key, scope] -> %{id: id, key: key, scope: scope} end)

    blocked = blocked_pairs(type)
    # Only a SHORT, single-token key is an acronym candidate — pair those against all
    # nodes (shorts ≪ n → this is ~O(shorts·n), not O(n²); the perf fix, code review).
    shorts = Enum.filter(nodes, &short_form?/1)

    for s <- shorts,
        l <- nodes,
        s.id != l.id,
        s.scope == l.scope,
        not MapSet.member?(blocked, pair_key(s.id, l.id)),
        acronym?(s.key, l.key) do
      %{alias_key: s.key, canonical_key: l.key, scope: s.scope}
    end
    |> drop_polysemous()
    |> Enum.take(limit)
  end

  # A short single-token key (SSP, k8s, MFA, i18n) — the only shape that can BE an
  # acronym. Excludes multi-word/long keys (they are the expansion, not the acronym).
  @spec short_form?(map()) :: boolean()
  defp short_form?(%{key: key}) do
    n = norm(key)
    String.length(n) in 2..12 and not String.contains?(String.trim(key), " ")
  end

  # POLYSEMY GUARD (council codex): if one short form is an acronym of MORE THAN ONE
  # long form in the SAME scope (e.g. SSP ⇒ "Self Service Password" AND "Supply Side
  # Platform"), it is AMBIGUOUS — auto-linking both would transitively fuse the two
  # senses through the short form (`forms/2` closure). Drop ALL of that form's
  # candidates in that scope; disambiguation needs context this pass doesn't have.
  @spec drop_polysemous([candidate()]) :: [candidate()]
  defp drop_polysemous(cands) do
    cands
    |> Enum.group_by(fn c -> {String.downcase(c.alias_key), c.scope} end)
    |> Enum.flat_map(fn {_k, group} ->
      if group |> Enum.map(& &1.canonical_key) |> Enum.uniq() |> length() == 1,
        do: group,
        else: []
    end)
  end

  @doc """
  Run an acronym-synonym pass: `propose_acronyms/1` → a conservative confirm → `link/3`
  each confirmed pair. Precision-first (council): the confirm defaults to a strict LLM
  ("perfectly interchangeable? any doubt => no"); inject `:confirm_fun` in tests.
  Returns `%{proposed: n, linked: n}`.
  """
  @spec run_acronym_pass(keyword()) :: %{proposed: non_neg_integer(), linked: non_neg_integer()}
  def run_acronym_pass(opts \\ []) do
    type = Keyword.get(opts, :type, "concept")
    confirm = Keyword.get(opts, :confirm_fun, &llm_confirm/1)
    proposed = propose_acronyms(opts)

    linked =
      Enum.count(proposed, fn c ->
        confirm.(c) and
          match?({:ok, _}, link(c.alias_key, c.canonical_key, type: type, scope: c.scope))
      end)

    %{proposed: length(proposed), linked: linked}
  end

  @doc "The node id for `(type, key)`, raising if absent (test/ops helper)."
  @spec node_id!(String.t(), String.t()) :: integer()
  def node_id!(type, key) do
    {:ok, id} = node_id(type, key)
    id
  end

  # --- internals -------------------------------------------------------------

  # {min,max} pairs already joined by synonym_of OR sibling_of — excluded from proposal
  # (already-folded, or explicitly contrastive). Symmetric, so normalize by id order.
  @spec blocked_pairs(String.t()) :: MapSet.t()
  defp blocked_pairs(type) do
    Repo.query!(
      """
      SELECT e.src, e.dst FROM edge e
        JOIN node a ON a.id = e.src AND a.type = $2
        JOIN node b ON b.id = e.dst AND b.type = $2
       WHERE e.type = $1 OR e.type = $3
      """,
      [@relation, type, @sibling]
    ).rows
    |> Enum.map(fn [s, d] -> pair_key(s, d) end)
    |> MapSet.new()
  end

  @spec pair_key(integer(), integer()) :: {integer(), integer()}
  defp pair_key(a, b), do: if(a <= b, do: {a, b}, else: {b, a})

  # COMPONENT-AWARE sibling guard (council gemini): refuse a link if ANY node in `a`'s
  # existing synonym component is `sibling_of`-related to ANY node in `c`'s component —
  # not just a direct a↔c sibling edge (blocked_pairs catches that). Prevents a chain
  # like SSP—synonym—X, X—sibling—Y from folding a contrastive pair into one component.
  @spec no_sibling_conflict(integer(), integer(), String.t()) :: :ok | {:error, :sibling_conflict}
  defp no_sibling_conflict(a, c, scope) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        WITH RECURSIVE ca(id) AS (
          SELECT $1::bigint
          UNION
          SELECT CASE WHEN e.src = ca.id THEN e.dst ELSE e.src END
            FROM ca JOIN edge e
              ON e.type = 'synonym_of' AND e.reward >= 0 AND e.visibility_scope = $3
             AND (e.src = ca.id OR e.dst = ca.id)
        ),
        cc(id) AS (
          SELECT $2::bigint
          UNION
          SELECT CASE WHEN e.src = cc.id THEN e.dst ELSE e.src END
            FROM cc JOIN edge e
              ON e.type = 'synonym_of' AND e.reward >= 0 AND e.visibility_scope = $3
             AND (e.src = cc.id OR e.dst = cc.id)
        )
        SELECT count(*) FROM edge s
         WHERE s.type = 'sibling_of'
           AND ((s.src IN (SELECT id FROM ca) AND s.dst IN (SELECT id FROM cc))
             OR (s.src IN (SELECT id FROM cc) AND s.dst IN (SELECT id FROM ca)))
        """,
        [a, c, scope]
      )

    if n == 0, do: :ok, else: {:error, :sibling_conflict}
  end

  # Conservative LLM confirm (precision over recall — a false synonym poisons every
  # query touching the concept). Any doubt / parse failure / model error => false.
  @spec llm_confirm(candidate()) :: boolean()
  defp llm_confirm(%{alias_key: a, canonical_key: b}) do
    model = Application.get_env(:swarm, :entity_resolution, [])[:model] || "qwen3:14b"
    prompt = "A: #{a}\nB: #{b}\n\nInterchangeable synonyms? JSON:"

    case Generation.generate(model, prompt, json: false, system: @confirm_system) do
      {:ok, raw} -> parse_same(raw)
      {:error, _} -> false
    end
  end

  @spec parse_same(String.t()) :: boolean()
  defp parse_same(raw) do
    case Regex.run(~r/\{[^}]*\}/, raw) do
      [json] -> match?({:ok, %{"same" => true}}, Jason.decode(json))
      _ -> false
    end
  end

  @spec initialism?(String.t(), [String.t()]) :: boolean()
  defp initialism?(s, words) do
    s == Enum.map_join(words, "", &String.first/1)
  end

  # first-letter + <inner-letter count> + last-letter, over a SINGLE long word.
  @spec numeronym?(String.t(), [String.t()]) :: boolean()
  defp numeronym?(s, [word]) do
    chars = String.graphemes(word)

    with true <- length(chars) >= 3,
         first <- hd(chars),
         last <- List.last(chars),
         inner <- length(chars) - 2 do
      s == "#{first}#{inner}#{last}"
    end
  end

  defp numeronym?(_s, _words), do: false

  @spec norm(String.t()) :: String.t()
  defp norm(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
  end

  @spec node_id(String.t(), String.t()) :: {:ok, integer()} | {:error, :unknown_node}
  defp node_id(type, key) do
    case Repo.query!("SELECT id FROM node WHERE type = $1 AND key = $2", [type, key]) do
      %{rows: [[id]]} -> {:ok, id}
      _ -> {:error, :unknown_node}
    end
  end

  @spec distinct(String.t(), String.t()) :: :ok | {:error, :self_link}
  defp distinct(k1, k2), do: if(k1 == k2, do: {:error, :self_link}, else: :ok)

  # The shared endpoint scope, or `:cross_scope` if they differ (mirror ER's refusal
  # — a synonym edge wider than an endpoint would leak the narrower concept). Returns
  # the scope so `link` can stamp the edge with it (never a caller default).
  @spec shared_scope(integer(), integer()) :: {:ok, String.t()} | {:error, :cross_scope}
  defp shared_scope(a, c) do
    %{rows: [[sa]]} = Repo.query!("SELECT scope FROM node WHERE id = $1", [a])
    %{rows: [[sc]]} = Repo.query!("SELECT scope FROM node WHERE id = $1", [c])
    if sa == sc, do: {:ok, sa}, else: {:error, :cross_scope}
  end
end
