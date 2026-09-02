defmodule Swarm.Graph.Retrieval do
  @moduledoc """
  Hybrid-then-traverse retrieval (swarm ADR-14 §5) — the "grep/find on steroids"
  query, all in Postgres, scope-filtered, no per-query LLM.

  **Stage 1 — candidate spans.** A lexical arm (`tsvector`/GIN over `chunk.text`)
  and a dense arm (pgvector HNSW over `chunk.vec`) are fused by **Reciprocal Rank
  Fusion** (`Σ 1/(k+rank)`) in SQL. The scope predicate is applied on **both**
  arms (join `node.scope ∈ asker-visible scopes`), so a chunk a viewer may not see
  never enters either ranking — privacy is enforced before fusion, not after. The
  fused chunk hits are grouped by `node_id` (spans → memories).

  **Stage 2 — memories → THE memory.** The seed `node_id`s feed the native
  recursive-CTE graph traversal (`Swarm.Graph.Traverse`), whose confidence calculus
  scores multi-hop paths; the result is the answer-result algebra
  (`:found` / `:not_found`).

  Every memory carries **{node identity, cited span(s), score, confidence}** — a
  chunk never surfaces bare (the cited-span rule). `score` is retrieval relevance
  (fused RRF); `confidence` is graph trust (the node's reliability) — two axes,
  both reported.

  The only sanctioned escalation (a small **local** cross-encoder rerank for
  hard/ambiguous queries) is deliberately **not** wired here — it is opt-in future
  work, never the default. No corpus-wide LLM summaries, no default LLM rerank, no
  ColBERT.
  """

  alias Swarm.Graph.Corroboration
  alias Swarm.Graph.DocumentKind
  alias Swarm.Graph.Traverse
  alias Swarm.ML.Embeddings
  alias Swarm.Repo

  @typedoc """
  A retrieved memory: node identity + cited spans + three orthogonal numbers —
  `score` (ranking), `relevance` (absolute dense cosine, 0..1; the calibrated
  retrieval-confidence signal), and `confidence` (graph trust = node reliability).
  """
  @type memory :: %{
          node_id: integer(),
          type: String.t(),
          key: String.t(),
          score: float(),
          relevance: float(),
          confidence: float(),
          document_kind: DocumentKind.kind(),
          structural_evidence: [String.t()],
          source_ref: String.t() | nil,
          spans: [%{ordinal: integer(), text: String.t()}]
        }

  # Default relevance floor on absolute dense cosine. Below it, a dense-only hit is
  # treated as out-of-scope (the system can say "I don't know"). Calibrated on the
  # live slice (in-scope cosine ≳ 0.5, out-of-scope ≲ 0.49); overridable per call
  # (`:floor`) and via config. A lexical (keyword) hit bypasses the floor — an exact
  # term match is relevant regardless of vector similarity.
  @default_floor 0.45

  @typedoc "The two-stage result."
  @type result :: %{status: :found | :not_found, memories: [memory()], expanded: [map()]}

  @doc """
  Retrieve memories for `query` visible to `scopes`. `opts`:

    * `:limit` — max memories returned (default 10)
    * `:candidates` — per-arm candidate chunks before fusion (default 50)
    * `:rrf_k` — RRF constant (default 60)
    * `:spans` — cited spans kept per memory (default 3)
    * `:query_vec` — a precomputed query embedding (list); when absent the query is
      embedded via the ML boundary, and if that is unavailable the dense arm is
      skipped (lexical-only — still correct, just narrower)
    * `:embed_fun` — inject the query embedder (tests/live measurement)
    * `:dense` — include the dense arm (default true); `false` is lexical-only
      (used to measure the dense arm's marginal contribution)
    * `:expand` — run stage-2 traversal (default true)
    * `:max_depth` — traversal depth (default 2)
  """
  @spec search(String.t(), [String.t()], keyword()) :: result()
  def search(query, scopes, opts \\ [])

  def search(_query, [], _opts), do: %{status: :not_found, memories: [], expanded: []}

  def search(query, scopes, opts) when is_binary(query) and is_list(scopes) do
    limit = Keyword.get(opts, :limit, 10)
    candidates = Keyword.get(opts, :candidates, 50)
    k = Keyword.get(opts, :rrf_k, 60)
    spans = Keyword.get(opts, :spans, 3)
    floor = Keyword.get(opts, :floor, configured_floor())
    {lex_w, dense_w, title_w} = weights(opts)

    # An explicitly supplied query vector ALWAYS wins (tests, callers that pre-embed);
    # otherwise embed only if the dense arm is enabled (config-gated, so unit tests
    # without an ML sidecar skip the round-trip and run lexical-only).
    qvec =
      cond do
        vec = Keyword.get(opts, :query_vec) -> Pgvector.new(vec)
        Keyword.get(opts, :dense, dense_default?()) -> embed_query(query, opts)
        true -> nil
      end

    # Concept-synonymy query expansion (ADR-17 substrate): the LEXICAL/title arm sees
    # the user's query augmented with the synonym surface forms of any concept it names
    # (so "SSP" also matches "Self Service Password" chunks); the dense arm above
    # already embedded the ORIGINAL NL query. Config/opt-gated + scope-enforced.
    lex_query =
      if synonym_expansion?(opts),
        do: Swarm.Synonymy.expand_query(query, scopes, types: synonym_types()),
        else: query

    memories =
      lex_query
      |> fused_chunks(scopes, candidates, k, qvec, lex_w, dense_w)
      |> group_by_node(spans, floor, k, title_w)
      |> Enum.sort_by(& &1.score, :desc)
      |> attach_identity(scopes)
      |> rerank_by_document_kind(query)
      |> Enum.take(limit)

    expanded =
      if Keyword.get(opts, :expand, true),
        do: expand(memories, scopes, Keyword.get(opts, :max_depth, 2)),
        else: []

    %{
      status: if(memories == [], do: :not_found, else: :found),
      memories: memories,
      expanded: expanded
    }
  end

  # --- stage 1: fused candidate spans ---------------------------------------

  @typep fused :: %{
           node_id: integer(),
           ordinal: integer(),
           text: String.t(),
           rrf: float(),
           cos: float() | nil,
           lex: boolean(),
           title_rnk: integer() | nil
         }

  @spec fused_chunks(
          String.t(),
          [String.t()],
          pos_integer(),
          pos_integer(),
          Pgvector.t() | nil,
          float(),
          float()
        ) :: [fused()]
  # Lexical query for the FTS arm: an OR of the query's content lexemes (stopwords,
  # punctuation, 1-char tokens dropped). `plainto_tsquery` ANDs EVERY term, so one
  # extra word the answer page lacks (e.g. "Nebula" for a page titled "Public IP")
  # excluded the right page entirely; OR-recall + `ts_rank` (which scores by term
  # coverage) brings it back and ranks multi-term matches higher. Empty (all stopwords)
  # ⇒ "" — `to_tsquery('simple','')` matches nothing, so the arm is a no-op and the
  # dense arm alone applies (the prior behaviour, never worse).
  @lex_stopwords ~w(a an and are as at be but by for from how if in into is it of on or
                    that the this to was what when where which who why with хто що як де чи)
  @spec or_tsquery(String.t()) :: String.t()
  defp or_tsquery(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2 or &1 in @lex_stopwords))
    |> Enum.uniq()
    |> Enum.join(" | ")
  end

  # Dispatch the lexical arm by the configured engine (ADR-0016). `:native` (default)
  # is the hand-rolled `ts_rank` + title-arm; `:bm25` is pg_search/Tantivy (field-
  # boosted body+title, scope filtered in-index). Both keep the dense arm + RRF fusion.
  defp fused_chunks(query, scopes, candidates, k, qvec, lex_w, dense_w) do
    case lexical_engine() do
      :bm25 -> fused_bm25(query, scopes, candidates, k, qvec, lex_w, dense_w)
      _ -> fused_native(query, scopes, candidates, k, qvec, lex_w, dense_w)
    end
  end

  defp lexical_engine do
    Application.get_env(:swarm, :retrieval, [])[:lexical_engine] || :native
  end

  # --- bm25 lexical arm (pg_search/Tantivy — ADR-0016) ----------------------
  # A Tantivy arm over `chunk`: `paradedb.match` on the body ⊕ a title field-boost (so a
  # title-only page enters the candidate pool), scope filtered IN-index (filter-before-
  # rank — the no-leak property). The `@@@` is a `boolean` with a `must` of TWO
  # sub-queries: (1) a scope filter — a `term_set` of EXACT `term`s over the viewer's
  # scopes (built from `$6` via `array_agg`, NOT string-built — no query-syntax metachar
  # or empty-`scope:()` hazard, exact not tokenized), and (2) a should-only boolean over
  # body+boosted-title (Tantivy requires ≥1 should to match, so scope alone never matches).
  # **Title-arm fusion (integration tuning, 2026-07-01):** bm25's in-score title-boost is
  # compressed by score→rank→RRF, so on title-lookups it lost to native's dedicated
  # per-node boost. Fix: bm25 replaces only the BODY-lexical ranking; the SAME native
  # title arm (the `titled` CTE + the aggressive per-node `title_weight` boost applied in
  # `group_by_node`) rides ON TOP — bm25 surfaces the title-only page's chunks, the title
  # arm then floats them. So `title_rnk` is populated (not NULL) here too.
  # Belt-and-suspenders: the authoritative `node.scope` join stays as the outer belt.
  # NB (council): a shared bm25 index's IDF is corpus-global → bm25 SCORES carry a
  # corpus-global term-statistic; RESULT rows are scope-safe (belt + in-index filter), but
  # term-existence via score-probing is a residual for the flip gate (`bm25-index-hardening`).
  @bm25_scope_filter "paradedb.term_set(terms => (SELECT array_agg(paradedb.term('scope', s)) FROM unnest($6::text[]) AS s))"
  @bm25_query "paradedb.boolean(must => ARRAY[#{@bm25_scope_filter}, paradedb.boolean(should => ARRAY[paradedb.match('text', $1), paradedb.boost(factor => $7::real, query => paradedb.match('title', $1))])])"

  # The native title arm CTE (ts_rank_cd over node.key, scope-filtered, ordered+LIMITed),
  # reused verbatim in bm25 mode so title-lookups keep the aggressive per-node boost.
  # `titled_q` is the tsvector query param index, `scope_p` the scopes[] param index.
  defp titled_cte(titled_q, scope_p) do
    """
    titled AS (
      SELECT node_id, row_number() OVER (ORDER BY trank DESC, node_id) AS rnk
      FROM (
        SELECT n.id AS node_id, ts_rank_cd(to_tsvector('simple', n.key), to_tsquery('simple', $#{titled_q})) AS trank
        FROM node n
        WHERE n.scope = ANY($#{scope_p}) AND to_tsvector('simple', n.key) @@ to_tsquery('simple', $#{titled_q})
        ORDER BY trank DESC, n.id
        LIMIT $3
      ) tn
    )
    """
  end

  defp fused_bm25(query, scopes, candidates, k, nil, lex_w, _dense_w) do
    sql = """
    WITH #{titled_cte(8, 2)},
    lexical AS (
      SELECT chunk_id, node_id, ordinal, text,
             row_number() OVER (ORDER BY score DESC) AS rnk, $5::float8 AS w
      FROM (
        SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text, paradedb.score(k.id) AS score
        FROM chunk k JOIN node n ON n.id = k.node_id AND n.scope = ANY($2)
        WHERE k.id @@@ #{@bm25_query}
        ORDER BY score DESC
        LIMIT $3
      ) bs
    ),
    fused AS (
      SELECT node_id, ordinal, text, chunk_id,
             sum(w / ($4 + rnk))::float8 AS body_rrf,
             NULL::float8 AS cos, true AS lex
      FROM lexical GROUP BY chunk_id, node_id, ordinal, text
    )
    SELECT f.node_id, f.ordinal, f.text, f.body_rrf, f.cos, f.lex, t.rnk AS title_rnk
    FROM fused f LEFT JOIN titled t ON t.node_id = f.node_id
    ORDER BY f.body_rrf DESC
    """

    run_fused(sql, [query, scopes, candidates, k, lex_w, scopes, bm25_boost(), or_tsquery(query)])
  end

  defp fused_bm25(query, scopes, candidates, k, qvec, lex_w, dense_w) do
    sql = """
    WITH #{titled_cte(10, 2)},
    lexical AS (
      SELECT chunk_id, node_id, ordinal, text,
             row_number() OVER (ORDER BY score DESC) AS rnk,
             NULL::float8 AS cos, true AS lex, $5::float8 AS w
      FROM (
        SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text, paradedb.score(k.id) AS score
        FROM chunk k JOIN node n ON n.id = k.node_id AND n.scope = ANY($2)
        WHERE k.id @@@ #{@bm25_query}
        ORDER BY score DESC
        LIMIT $3
      ) bs
    ),
    dense AS (
      SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text,
             row_number() OVER (ORDER BY k.vec <=> $8) AS rnk,
             (1.0 - (k.vec <=> $8))::float8 AS cos, false AS lex, $9::float8 AS w
      FROM chunk k JOIN node n ON n.id = k.node_id
      WHERE n.scope = ANY($2) AND k.vec IS NOT NULL
      ORDER BY k.vec <=> $8
      LIMIT $3
    ),
    fused AS (
      SELECT node_id, ordinal, text, chunk_id,
             sum(w / ($4 + rnk))::float8 AS body_rrf,
             max(cos) AS cos, bool_or(lex) AS lex
      FROM (SELECT * FROM lexical UNION ALL SELECT * FROM dense) u
      GROUP BY chunk_id, node_id, ordinal, text
    )
    SELECT f.node_id, f.ordinal, f.text, f.body_rrf, f.cos, f.lex, t.rnk AS title_rnk
    FROM fused f LEFT JOIN titled t ON t.node_id = f.node_id
    ORDER BY f.body_rrf DESC
    """

    run_fused(sql, [
      query,
      scopes,
      candidates,
      k,
      lex_w,
      scopes,
      bm25_boost(),
      qvec,
      dense_w,
      or_tsquery(query)
    ])
  end

  defp bm25_boost do
    Application.get_env(:swarm, :retrieval, [])[:bm25_title_boost] || 2.0
  end

  defp fused_native(query, scopes, candidates, k, nil, lex_w, _dense_w) do
    # Lexical-only (no query vector): a body-keyword match is the only per-chunk
    # signal, so `cos` is unknown (nil). The **title arm** (ADR-0016) is the
    # `titled` CTE — in-scope nodes ranked by `ts_rank_cd` over `node.key` — LEFT
    # JOINed so each surviving chunk learns its node's title rank; the per-node
    # title boost is applied ONCE in `group_by_node` (never multiplied by chunk
    # count). Scope is enforced on BOTH the body arm and `titled` (no-leak). The
    # body ranking is computed + `LIMIT`ed in a subquery BEFORE `row_number`, so the
    # top-N by `ts_rank` is what survives (an un-ordered `LIMIT` could keep arbitrary
    # rows).
    sql = """
    WITH q AS (SELECT to_tsquery('simple', $1) AS tsq),
    titled AS (
      SELECT node_id, row_number() OVER (ORDER BY trank DESC) AS rnk
      FROM (
        SELECT n.id AS node_id, ts_rank_cd(to_tsvector('simple', n.key), (SELECT tsq FROM q)) AS trank
        FROM node n
        WHERE n.scope = ANY($2) AND to_tsvector('simple', n.key) @@ (SELECT tsq FROM q)
        ORDER BY trank DESC
        LIMIT $3
      ) tn
    ),
    lexical AS (
      SELECT chunk_id, node_id, ordinal, text,
             row_number() OVER (ORDER BY score DESC) AS rnk, $5::float8 AS w
      FROM (
        SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text,
               ts_rank(to_tsvector('simple', k.text), (SELECT tsq FROM q)) AS score
        FROM chunk k JOIN node n ON n.id = k.node_id
        WHERE n.scope = ANY($2) AND to_tsvector('simple', k.text) @@ (SELECT tsq FROM q)
        ORDER BY score DESC
        LIMIT $3
      ) ls
    ),
    fused AS (
      SELECT node_id, ordinal, text, chunk_id,
             sum(w / ($4 + rnk))::float8 AS body_rrf,
             NULL::float8 AS cos, true AS lex
      FROM lexical
      GROUP BY chunk_id, node_id, ordinal, text
    )
    SELECT f.node_id, f.ordinal, f.text, f.body_rrf, f.cos, f.lex, t.rnk AS title_rnk
    FROM fused f LEFT JOIN titled t ON t.node_id = f.node_id
    ORDER BY f.body_rrf DESC
    """

    run_fused(sql, [or_tsquery(query), scopes, candidates, k, lex_w])
  end

  defp fused_native(query, scopes, candidates, k, qvec, lex_w, dense_w) do
    # Body arms (lexical + dense) carry their rank (for weighted RRF) plus the dense
    # arm's ABSOLUTE cosine (`1 - distance`) and a lexical-hit flag; fused per chunk.
    # **Weighted RRF** (Card 7): the lexical term is scaled by `$6`, the dense term
    # by `$7`, so an exact keyword hit resists demotion by a multi-chunk dense
    # "magnet"; PARAPHRASE ranking is untouched. The **title arm** (ADR-0016) is the
    # `titled` CTE (in-scope nodes ranked by `ts_rank_cd` over `node.key`), LEFT
    # JOINed so each chunk learns its node's title rank; the per-node title boost is
    # added ONCE in `group_by_node`, so a page whose title IS the query floats over
    # body-only mentions WITHOUT a chunk-count multiplier and WITHOUT bypassing the
    # relevance gate (it re-orders survivors, it does not admit new ones). Absolute
    # cosine still drives the relevance floor and is the reported relevance. The
    # lexical body arm is ordered + `LIMIT`ed BEFORE `row_number` (top-N, not
    # arbitrary rows); dense already orders by distance. Scope on EVERY arm.
    sql = """
    WITH q AS (SELECT to_tsquery('simple', $1) AS tsq),
    titled AS (
      SELECT node_id, row_number() OVER (ORDER BY trank DESC) AS rnk
      FROM (
        SELECT n.id AS node_id, ts_rank_cd(to_tsvector('simple', n.key), (SELECT tsq FROM q)) AS trank
        FROM node n
        WHERE n.scope = ANY($2) AND to_tsvector('simple', n.key) @@ (SELECT tsq FROM q)
        ORDER BY trank DESC
        LIMIT $3
      ) tn
    ),
    lexical AS (
      SELECT chunk_id, node_id, ordinal, text,
             row_number() OVER (ORDER BY score DESC) AS rnk,
             NULL::float8 AS cos, true AS lex, $6::float8 AS w
      FROM (
        SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text,
               ts_rank(to_tsvector('simple', k.text), (SELECT tsq FROM q)) AS score
        FROM chunk k JOIN node n ON n.id = k.node_id
        WHERE n.scope = ANY($2) AND to_tsvector('simple', k.text) @@ (SELECT tsq FROM q)
        ORDER BY score DESC
        LIMIT $3
      ) ls
    ),
    dense AS (
      SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text,
             row_number() OVER (ORDER BY k.vec <=> $5) AS rnk,
             (1.0 - (k.vec <=> $5))::float8 AS cos, false AS lex, $7::float8 AS w
      FROM chunk k JOIN node n ON n.id = k.node_id
      WHERE n.scope = ANY($2) AND k.vec IS NOT NULL
      ORDER BY k.vec <=> $5
      LIMIT $3
    ),
    fused AS (
      SELECT node_id, ordinal, text, chunk_id,
             sum(w / ($4 + rnk))::float8 AS body_rrf,
             max(cos) AS cos, bool_or(lex) AS lex
      FROM (SELECT * FROM lexical UNION ALL SELECT * FROM dense) u
      GROUP BY chunk_id, node_id, ordinal, text
    )
    SELECT f.node_id, f.ordinal, f.text, f.body_rrf, f.cos, f.lex, t.rnk AS title_rnk
    FROM fused f LEFT JOIN titled t ON t.node_id = f.node_id
    ORDER BY f.body_rrf DESC
    """

    run_fused(sql, [or_tsquery(query), scopes, candidates, k, qvec, lex_w, dense_w])
  end

  defp run_fused(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [node_id, ordinal, text, body_rrf, cos, lex, title_rnk] ->
      %{
        node_id: node_id,
        ordinal: ordinal,
        text: text,
        rrf: body_rrf,
        cos: cos,
        lex: lex,
        title_rnk: title_rnk
      }
    end)
  end

  # Collapse fused chunk hits into per-node memories. A chunk is kept only if it
  # clears the relevance gate (lexical hit OR cosine ≥ floor); RRF then ranks the
  # SURVIVORS, so a "magnet" chunk that is merely a global near-neighbour (mid
  # cosine, no keyword match on this query) is dropped before it can outrank the
  # true answer. A node with no surviving chunk is dropped entirely — that is how
  # an out-of-scope query collapses to `:not_found`.
  defp group_by_node(chunks, spans_per, floor, k, title_w) do
    chunks
    |> Enum.group_by(& &1.node_id)
    |> Enum.flat_map(fn {node_id, hits} ->
      case Enum.filter(hits, &chunk_relevant?(&1, floor)) do
        [] -> []
        kept -> [node_memory(node_id, kept, spans_per, k, title_w)]
      end
    end)
  end

  # One memory from a node's surviving chunks: the body score is the RRF sum over
  # survivors; the title arm (ADR-0016) adds a SINGLE per-node boost (title rank is
  # uniform across the node's chunks via the LEFT JOIN — take any non-nil), so it is
  # never multiplied by the node's chunk count and only re-orders nodes that already
  # have a surviving chunk (no floor bypass → no flooding). Relevance is the best
  # absolute cosine among survivors.
  defp node_memory(node_id, kept, spans_per, k, title_w) do
    body = kept |> Enum.map(& &1.rrf) |> Enum.sum()

    title_boost =
      case Enum.find_value(kept, & &1.title_rnk) do
        nil -> 0.0
        rnk -> title_w / (k + rnk)
      end

    %{
      node_id: node_id,
      score: body + title_boost,
      relevance: kept |> Enum.map(&(&1.cos || 0.0)) |> Enum.max(),
      spans:
        kept
        |> Enum.sort_by(& &1.rrf, :desc)
        |> Enum.take(spans_per)
        |> Enum.map(&%{ordinal: &1.ordinal, text: &1.text})
    }
  end

  # The relevance gate: a keyword (lexical) hit is relevant regardless of vector
  # similarity; a dense-only hit must clear the cosine floor. A title match does
  # NOT bypass this gate (ADR-0016) — it boosts a node's SURVIVING chunks, so a
  # title match with no relevant chunk never surfaces (no flooding).
  defp chunk_relevant?(%{lex: true}, _floor), do: true
  defp chunk_relevant?(%{cos: cos}, floor) when is_float(cos), do: cos >= floor
  defp chunk_relevant?(_chunk, _floor), do: false

  defp configured_floor do
    Application.get_env(:swarm, :retrieval, [])[:floor] || @default_floor
  end

  # Concept-synonymy query expansion (ADR-17). Per-call `:synonym_expansion` overrides
  # config; defaults ON (a query never resolves fewer forms than its literal self, so
  # expansion only adds recall). Set false to A/B or in a corpus with no synonym edges.
  defp synonym_expansion?(opts) do
    case Keyword.get(opts, :synonym_expansion) do
      nil -> Application.get_env(:swarm, :retrieval, [])[:synonym_expansion] != false
      v -> v
    end
  end

  # The concept-bearing node types the synonym expansion resolves against. On this
  # deployment concepts live in `entity`/`article` (enrichment + page titles), not a
  # `concept` type — so the default spans all three (live QA 2026-07-05). Only LINKED
  # forms expand, so a wide type set adds no noise beyond confirmed synonyms.
  defp synonym_types do
    Application.get_env(:swarm, :retrieval, [])[:synonym_types] || ~w(concept entity article)
  end

  # Weighted-RRF arm weights (Card 7 + ADR-0016). Per-call
  # `:lex_weight`/`:dense_weight`/`:title_weight` override config, which overrides
  # the equal-weight default (1.0 — identical to the original behaviour, so nothing
  # changes until a weight is set). `title_weight` scales the title arm: above the
  # body weights it floats a title-matched page over body-only mentions.
  defp weights(opts) do
    cfg = Application.get_env(:swarm, :retrieval, [])
    lex = Keyword.get(opts, :lex_weight) || cfg[:lex_weight] || 1.0
    dense = Keyword.get(opts, :dense_weight) || cfg[:dense_weight] || 1.0
    title = Keyword.get(opts, :title_weight) || cfg[:title_weight] || 1.0
    {lex / 1, dense / 1, title / 1}
  end

  # Whether the dense arm is on by default. True in production; a deployment (or
  # test env) with no embedding sidecar sets `config :swarm, :retrieval, dense: false`
  # so retrieval runs lexical-only instead of paying an unreachable-ML round-trip.
  defp dense_default? do
    Application.get_env(:swarm, :retrieval, [])[:dense] != false
  end

  # Attach node identity + trust — every memory names its node. `confidence` is
  # the node's evidential corroboration (ADR-13: combine_typed over independent
  # origins) when it has typed assertions, else its intrinsic reliability. Both
  # the identity meta and the corroboration are batched (one query each), so this
  # stays bounded by the result set, never a graph scan.
  defp attach_identity([], _scopes), do: []

  defp attach_identity(memories, scopes) do
    ids = Enum.map(memories, & &1.node_id)

    meta =
      Repo.query!(
        """
        SELECT n.id, n.type, n.key, n.reliability, c.source_ref
        FROM node n
        LEFT JOIN content c ON c.node_id = n.id
        WHERE n.id = ANY($1)
        """,
        [ids]
      )
      |> Map.get(:rows)
      |> Map.new(fn [id, type, key, rel, source_ref] -> {id, {type, key, rel, source_ref}} end)

    corr = Corroboration.for_nodes(ids, scopes: scopes)
    evidence = structural_evidence(ids, scopes)

    Enum.map(memories, fn m ->
      {type, key, rel, source_ref} = Map.get(meta, m.node_id, {nil, nil, 0.0, nil})
      # Corroboration when the node carries independent typed evidence; otherwise
      # fall back to intrinsic reliability (an un-enriched node is not penalised).
      confidence = Map.get(corr, m.node_id, rel)

      Map.merge(m, %{
        type: type,
        key: key,
        confidence: confidence,
        structural_evidence: Map.get(evidence, m.node_id, []),
        source_ref: source_ref,
        relevance: Float.round(m.relevance, 4)
      })
    end)
  end

  defp structural_evidence(ids, scopes) do
    Repo.query!(
      """
      SELECT src, array_agg(DISTINCT type ORDER BY type)
      FROM edge
      WHERE src = ANY($1) AND visibility_scope = ANY($2) AND type = ANY($3)
      GROUP BY src
      """,
      [ids, scopes, ["has_step"]]
    )
    |> Map.get(:rows)
    |> Map.new(fn [node_id, relations] -> {node_id, relations} end)
  end

  # Ontology small-slice: kind is a retrieval-time hint, not a graph label. It only reorders the
  # already scope-filtered, already relevant memory set; it never admits or filters rows.
  defp rerank_by_document_kind(memories, query) do
    query_kind = DocumentKind.query_kind(query)

    memories
    |> Enum.map(fn memory ->
      kind = DocumentKind.classify(memory)

      memory
      |> Map.put(:document_kind, kind)
      |> Map.update!(:score, &(&1 * kind_factor(query_kind, kind)))
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp kind_factor(:unknown, _kind), do: 1.0
  defp kind_factor(kind, kind), do: 1.15
  defp kind_factor(:policy, :procedure), do: 0.75
  defp kind_factor(_query_kind, _doc_kind), do: 1.0

  # --- stage 2: traversal expansion -----------------------------------------

  # Feed the seed nodes into the native recursive-CTE walk; collect reached nodes
  # (excluding the seeds themselves) with their best-path confidence, scope-pruned.
  defp expand([], _scopes, _depth), do: []

  defp expand(memories, scopes, depth) do
    seeds = MapSet.new(memories, & &1.node_id)

    memories
    |> Enum.flat_map(fn m -> Traverse.traverse(m.node_id, depth, scopes: scopes) end)
    |> Enum.reject(&MapSet.member?(seeds, &1.id))
    |> Enum.reduce(%{}, fn hit, acc -> Map.update(acc, hit.id, hit, &stronger(&1, hit)) end)
    |> Map.values()
    |> Enum.sort_by(& &1.confidence, :desc)
  end

  # Keep the higher-confidence of two reaches of the same node (a node reachable
  # from several seeds takes its strongest path).
  defp stronger(a, b), do: if(b.confidence > a.confidence, do: b, else: a)

  # --- query embedding -------------------------------------------------------

  # Embed the query (injected `:embed_fun` or the real boundary). On any embed
  # failure the dense arm is skipped (nil) — the lexical arm still answers, so
  # retrieval degrades narrowly, never errors.
  @spec embed_query(String.t(), keyword()) :: Pgvector.t() | nil
  defp embed_query(query, opts) do
    embed_fun = Keyword.get(opts, :embed_fun)

    result =
      if embed_fun, do: embed_fun.([query]), else: default_embed([query])

    case result do
      {:ok, [vec | _], _model} -> Pgvector.new(vec)
      _ -> nil
    end
  end

  defp default_embed(texts) do
    case Embeddings.embed(texts) do
      {:ok, %{vectors: vectors, namespace: ns}} -> {:ok, vectors, ns}
      other -> other
    end
  end
end
