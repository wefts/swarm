defmodule Swarm.Graph.Claims do
  @moduledoc """
  Claim-aware answering (the precise-lookup path) — surface the enrichment claim
  graph as FACTS for the consilium, rather than hoping the value-bearing chunk
  lands in the retrieved spans.

  The reward-gated enrichment worker writes extracted S-P-O triples as
  `evidence_kind: "claim"` edges between `entity` nodes (subject `--predicate-->`
  object), inheriting the source's scope (`Swarm.Enrichment.Worker`). So a question
  like "what is Nebula's public IP" can be answered DIRECTLY from a
  `Nebula --public_ip--> 203.0.113.7` claim edge, even when no single chunk carries
  the line.

  `for_query/3` resolves the query's significant terms to subject entities and
  returns their claim facts, **scope-enforced** (the edge's own `visibility_scope`
  AND both endpoint nodes must be within the asker's scopes — default-deny), refuted
  (`reward < 0`) excluded, ranked by reliability then corroboration, bounded.
  """

  alias Swarm.Repo

  require Logger

  @type fact :: %{
          subject: String.t(),
          predicate: String.t(),
          object: String.t(),
          reliability: float()
        }

  @default_limit 20
  @min_term_len 3
  @stopwords ~w(the a an of to and or for with about how what which why who when
                where is are was were do does did can could should would related
                show find list recent get see me my our your this that these those)

  @doc """
  Claim facts whose SUBJECT entity key matches a significant query term, visible to
  `scopes` (default-deny — empty ⇒ none). `opts`: `:limit` (default
  #{@default_limit}). Returns `[%{subject, predicate, object}]`, strongest first.
  """
  @spec for_query(String.t(), [String.t()], keyword()) :: [fact()]
  def for_query(_query, [], _opts), do: []

  def for_query(query, scopes, opts \\ []) when is_binary(query) and is_list(scopes) do
    case patterns(query) do
      [] ->
        []

      pats ->
        limit = Keyword.get(opts, :limit, @default_limit)
        query_claims(scopes, pats, limit)
    end
  end

  # Best-effort augmentation: a transport failure here must NOT raise out of the
  # answer turn (that would regress the T6 result algebra — code review). Retrieval
  # has already succeeded by the time we look up claims, so on a transient DB error
  # we degrade to NO facts (the answer still stands on its passages), never crash.
  @spec query_claims([String.t()], [String.t()], pos_integer()) :: [fact()]
  defp query_claims(scopes, pats, limit) do
    %{rows: rows} =
      Repo.query!(
        """
          SELECT s.key, e.type, o.key, e.reliability
            FROM edge e
            JOIN node s ON s.id = e.src AND s.scope = ANY($1::text[])
            JOIN node o ON o.id = e.dst AND o.scope = ANY($1::text[])
           WHERE e.evidence_kind = 'claim'
             AND e.visibility_scope = ANY($1::text[])
             AND e.reward >= 0
             AND s.key ILIKE ANY($2)
           ORDER BY e.reliability DESC, e.seen_count DESC, s.key, e.type, o.key
           LIMIT $3
        """,
        [scopes, pats, limit]
      )

    Enum.map(rows, fn [s, p, o, r] ->
      %{subject: s, predicate: p, object: o, reliability: r}
    end)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("claims: lookup failed, degrading to no facts (#{Exception.message(e)})")
      []
  end

  @doc "Render facts as grounding lines (`- subject predicate object`); `\"\"` if none."
  @spec to_grounding([fact()]) :: String.t()
  def to_grounding([]), do: ""

  def to_grounding(facts) do
    body = Enum.map_join(facts, "\n", fn f -> "- #{f.subject} #{f.predicate} #{f.object}" end)
    "Known facts (from the knowledge graph):\n" <> body
  end

  # Significant query terms → ILIKE patterns (drop stopwords and short tokens).
  @spec patterns(String.t()) :: [String.t()]
  defp patterns(query) do
    query
    |> String.downcase()
    |> String.split(~r/\W+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < @min_term_len or &1 in @stopwords))
    |> Enum.uniq()
    |> Enum.map(&"%#{&1}%")
  end
end
