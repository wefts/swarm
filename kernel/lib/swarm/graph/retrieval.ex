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
    qvec = if Keyword.get(opts, :dense, true), do: query_vec(query, opts), else: nil

    memories =
      query
      |> fused_chunks(scopes, candidates, k, qvec)
      |> group_by_node(spans, floor)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
      |> attach_identity()

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
           lex: boolean()
         }

  @spec fused_chunks(String.t(), [String.t()], pos_integer(), pos_integer(), Pgvector.t() | nil) ::
          [fused()]
  defp fused_chunks(query, scopes, candidates, k, nil) do
    # Lexical-only (no query vector): a keyword match is the only relevance signal,
    # so `cos` is unknown (nil) and every hit is a lexical hit.
    sql = """
    WITH q AS (SELECT plainto_tsquery('simple', $1) AS tsq),
    lexical AS (
      SELECT k.node_id, k.ordinal, k.text,
             row_number() OVER (
               ORDER BY ts_rank(to_tsvector('simple', k.text), (SELECT tsq FROM q)) DESC
             ) AS rnk
      FROM chunk k JOIN node n ON n.id = k.node_id
      WHERE n.scope = ANY($2) AND to_tsvector('simple', k.text) @@ (SELECT tsq FROM q)
      LIMIT $3
    )
    SELECT node_id, ordinal, text, (1.0 / ($4 + rnk))::float8 AS rrf,
           NULL::float8 AS cos, true AS lex
    FROM lexical
    ORDER BY rrf DESC
    """

    run_fused(sql, [query, scopes, candidates, k])
  end

  defp fused_chunks(query, scopes, candidates, k, qvec) do
    # Each arm carries its rank (for RRF) plus the dense arm's ABSOLUTE cosine
    # similarity (`1 - distance`) and a lexical-hit flag. Absolute cosine is the
    # calibratable relevance signal RRF-rank alone discards (the diagnosis): it
    # drives the relevance floor and the ranking, so out-of-scope queries (no
    # lexical hit, low cosine) can be refused and magnets cannot win on rank credit.
    sql = """
    WITH q AS (SELECT plainto_tsquery('simple', $1) AS tsq),
    lexical AS (
      SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text,
             row_number() OVER (
               ORDER BY ts_rank(to_tsvector('simple', k.text), (SELECT tsq FROM q)) DESC
             ) AS rnk,
             NULL::float8 AS cos, true AS lex
      FROM chunk k JOIN node n ON n.id = k.node_id
      WHERE n.scope = ANY($2) AND to_tsvector('simple', k.text) @@ (SELECT tsq FROM q)
      LIMIT $3
    ),
    dense AS (
      SELECT k.id AS chunk_id, k.node_id, k.ordinal, k.text,
             row_number() OVER (ORDER BY k.vec <=> $5) AS rnk,
             (1.0 - (k.vec <=> $5))::float8 AS cos, false AS lex
      FROM chunk k JOIN node n ON n.id = k.node_id
      WHERE n.scope = ANY($2) AND k.vec IS NOT NULL
      ORDER BY k.vec <=> $5
      LIMIT $3
    )
    SELECT node_id, ordinal, text,
           sum(1.0 / ($4 + rnk))::float8 AS rrf,
           max(cos) AS cos,
           bool_or(lex) AS lex
    FROM (SELECT * FROM lexical UNION ALL SELECT * FROM dense) u
    GROUP BY chunk_id, node_id, ordinal, text
    ORDER BY rrf DESC
    """

    run_fused(sql, [query, scopes, candidates, k, qvec])
  end

  defp run_fused(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [node_id, ordinal, text, rrf, cos, lex] ->
      %{node_id: node_id, ordinal: ordinal, text: text, rrf: rrf, cos: cos, lex: lex}
    end)
  end

  # Collapse fused chunk hits into per-node memories. A chunk is kept only if it
  # clears the relevance gate (lexical hit OR cosine ≥ floor); RRF then ranks the
  # SURVIVORS, so a "magnet" chunk that is merely a global near-neighbour (mid
  # cosine, no keyword match on this query) is dropped before it can outrank the
  # true answer. A node with no surviving chunk is dropped entirely — that is how
  # an out-of-scope query collapses to `:not_found`.
  defp group_by_node(chunks, spans_per, floor) do
    chunks
    |> Enum.group_by(& &1.node_id)
    |> Enum.flat_map(fn {node_id, hits} ->
      case Enum.filter(hits, &chunk_relevant?(&1, floor)) do
        [] ->
          []

        kept ->
          sorted = Enum.sort_by(kept, & &1.rrf, :desc)

          [
            %{
              node_id: node_id,
              score: kept |> Enum.map(& &1.rrf) |> Enum.sum(),
              relevance: kept |> Enum.map(&(&1.cos || 0.0)) |> Enum.max(),
              spans: sorted |> Enum.take(spans_per) |> Enum.map(&%{ordinal: &1.ordinal, text: &1.text})
            }
          ]
      end
    end)
  end

  # The relevance gate: a keyword (lexical) hit is relevant regardless of vector
  # similarity; a dense-only hit must clear the cosine floor.
  defp chunk_relevant?(%{lex: true}, _floor), do: true
  defp chunk_relevant?(%{cos: cos}, floor) when is_float(cos), do: cos >= floor
  defp chunk_relevant?(_chunk, _floor), do: false

  defp configured_floor do
    Application.get_env(:swarm, :retrieval, [])[:floor] || @default_floor
  end

  # Attach node identity + trust (reliability) — every memory names its node.
  defp attach_identity([]), do: []

  defp attach_identity(memories) do
    ids = Enum.map(memories, & &1.node_id)

    meta =
      Repo.query!("SELECT id, type, key, reliability FROM node WHERE id = ANY($1)", [ids])
      |> Map.get(:rows)
      |> Map.new(fn [id, type, key, rel] -> {id, {type, key, rel}} end)

    Enum.map(memories, fn m ->
      {type, key, rel} = Map.get(meta, m.node_id, {nil, nil, 0.0})
      # `relevance` (cosine) is already on the memory from grouping; add identity +
      # `confidence` (graph trust). Round relevance for a clean external number.
      Map.merge(m, %{type: type, key: key, confidence: rel, relevance: Float.round(m.relevance, 4)})
    end)
  end

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

  # The query vector: a precomputed `:query_vec`, else embed the query (injected or
  # the real boundary). On any embed failure the dense arm is skipped (nil) — the
  # lexical arm still answers, so retrieval degrades narrowly, never errors.
  @spec query_vec(String.t(), keyword()) :: Pgvector.t() | nil
  defp query_vec(query, opts) do
    case Keyword.get(opts, :query_vec) do
      nil -> embed_query(query, opts)
      vec -> Pgvector.new(vec)
    end
  end

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
