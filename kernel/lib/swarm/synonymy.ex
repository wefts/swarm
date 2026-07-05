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
  alias Swarm.Repo

  @relation "synonym_of"

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
          {:ok, map()} | {:error, :cross_scope | :self_link | :unknown_node | term()}
  def link(alias_key, canonical_key, opts \\ []) do
    type = Keyword.get(opts, :type, "concept")
    origin = Keyword.get(opts, :origin, "synonymy")

    with :ok <- distinct(alias_key, canonical_key),
         {:ok, a} <- node_id(type, alias_key),
         {:ok, c} <- node_id(type, canonical_key),
         {:ok, scope} <- shared_scope(a, c) do
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

  # --- internals -------------------------------------------------------------

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
