defmodule Swarm.Graph.Technology do
  @moduledoc """
  Read-only technology anchor view for the structural serve path.

  This is intentionally a projection over already-ingested, scoped corpus evidence:
  it does not materialize `instance_of concept:technology` edges. A term must be
  visible in scoped article/entity/content evidence before it can become a
  technology candidate, and the tier gate still applies the Stage-2 veto.
  """

  alias Swarm.Repo

  @candidate_min_support 2
  @candidate_limit 6
  @fact_limit 8

  @stopwords ~w(the a an of to and or for with about how what which why who when where is are was
                were do does did can could should would from your you my our this that these those
                known know tell show list give technology technologies tech software tool tools
                framework frameworks runtime runtimes cms service services use uses using used by)

  @doc "Technology-bearing candidate keys for a free-text query."
  @spec candidates(String.t(), [String.t()], keyword()) :: [String.t()]
  def candidates(query, scopes, opts \\ [])
  def candidates(_query, [], _opts), do: []

  def candidates(query, scopes, opts) when is_binary(query) and is_list(scopes) do
    limit = Keyword.get(opts, :limit, @candidate_limit)
    terms = query_terms(query)

    if terms == [] do
      []
    else
      %{rows: rows} =
        Repo.query!(
          """
          SELECT t.term, count(DISTINCT n.id) AS support
            FROM unnest($1::text[]) AS t(term)
            JOIN node n
              ON n.scope = ANY($2)
             AND n.type IN ('article', 'entity')
            LEFT JOIN content c ON c.node_id = n.id
           WHERE lower(n.key) LIKE '%' || t.term || '%'
              OR lower(coalesce(c.body, '')) LIKE '%' || t.term || '%'
           GROUP BY t.term
          HAVING count(DISTINCT n.id) >= $3
           ORDER BY support DESC, t.term
           LIMIT $4
          """,
          [terms, scopes, @candidate_min_support, limit]
        )

      Enum.map(rows, fn [term, _support] -> "technology:" <> term end)
    end
  end

  @doc "Facts known about a technology anchor key."
  @spec neighborhood(String.t(), [String.t()], keyword()) :: [map()]
  def neighborhood(key, scopes, opts \\ [])
  def neighborhood(_key, [], _opts), do: []

  def neighborhood("technology:" <> term, scopes, opts)
      when is_binary(term) and is_list(scopes) do
    limit = Keyword.get(opts, :limit, @fact_limit)
    min_corr = Keyword.get(opts, :min_corroboration, 1)

    (mentioned_in(term, scopes, limit) ++ used_by(term, scopes, limit))
    |> Enum.filter(&(Map.get(&1, :corroboration, 0) >= min_corr))
  end

  def neighborhood(_key, _scopes, _opts), do: []

  @doc "Technology keys render as their bare term."
  @spec display_subject(String.t()) :: String.t()
  def display_subject("technology:" <> term), do: term
  def display_subject(key), do: key

  @doc "Declared cardinality for technology relations."
  @spec cardinality(String.t()) :: :single | :many
  def cardinality(_relation), do: :many

  defp mentioned_in(term, scopes, limit) do
    like = "%" <> String.downcase(term) <> "%"

    %{rows: rows} =
      Repo.query!(
        """
        SELECT n.key, n.reliability::float8
          FROM node n
          LEFT JOIN content c ON c.node_id = n.id
         WHERE n.type = 'article'
           AND n.scope = ANY($1)
           AND (lower(n.key) LIKE $2 OR lower(coalesce(c.body, '')) LIKE $2)
         ORDER BY CASE WHEN lower(n.key) LIKE $2 THEN 0 ELSE 1 END,
                  n.reliability DESC,
                  n.key
         LIMIT $3
        """,
        [scopes, like, limit]
      )

    Enum.map(rows, fn [article, reliability] ->
      fact("mentioned_in", article, "article", min(reliability || 0.72, 0.72))
    end)
  end

  defp used_by(term, scopes, limit) do
    like = "%" <> String.downcase(term) <> "%"

    %{rows: rows} =
      Repo.query!(
        """
        SELECT s.key, s.type, e.seen_count, e.reliability::float8
          FROM edge e
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE e.type = 'uses'
           AND e.reward >= 0
           AND e.visibility_scope = ANY($1)
           AND s.scope = ANY($1)
           AND d.scope = ANY($1)
           AND lower(d.key) LIKE $2
         ORDER BY e.reliability DESC, s.key
         LIMIT $3
        """,
        [scopes, like, limit]
      )

    Enum.map(rows, fn [subject, kind, seen, reliability] ->
      fact("used_by", subject, kind, reliability, seen)
    end)
  end

  defp fact(relation, object, kind, reliability, corroboration \\ 1) do
    %{
      relation: relation,
      object: object,
      object_kind: kind,
      cardinality: cardinality(relation),
      corroboration: corroboration,
      effective_reliability: reliability || 0.6
    }
  end

  defp query_terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}+#.-]+/u, trim: true)
    |> Enum.map(&String.trim(&1, "."))
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stopwords))
    |> Enum.uniq()
  end
end
