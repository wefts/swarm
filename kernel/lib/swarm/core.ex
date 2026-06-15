defmodule Swarm.Core do
  @moduledoc """
  The kernel's outward Core API logic — the SINGLE VOICE (Domain 11). It owns
  cognition: route the question through the gate, retrieve from the graph
  (tier-tools) or escalate to the consilium, and compose ONE cited,
  confidence-tagged answer. Channels (CLI, web, chat) only render this; they hold
  no cognition.

  Explainability: every answer carries its citations — the "because Y" behind
  "I said X". Fail-loud: a failed escalation returns a low-confidence answer with
  no citations, never raw unsynthesized text.
  """

  alias Swarm.{Consilium, Gate, Repo}

  @default_scopes ["public"]
  @search_limit 10
  @stopwords ~w(the a an of to and or for with about how what which why who when
                where is are was were do does did can could should would related
                show find list recent get see me my our your this that these those)

  @type citation :: %{source: String.t(), ref: String.t(), confidence: float()}
  @type answer :: %{
          answer: String.t(),
          confidence: float(),
          tier: String.t(),
          citations: [citation()]
        }
  @type hit :: %{id: integer(), type: String.t(), key: String.t(), score: float()}

  @doc "Answer a question (the single voice). `opts`: `:scopes`, plus gate/consilium injectables."
  @spec ask(String.t(), keyword()) :: answer()
  def ask(query, opts \\ []) when is_binary(query) do
    scopes = Keyword.get(opts, :scopes, @default_scopes)

    case Gate.route(query, opts).tier do
      :tier0 -> greeting()
      :tier_tools -> tools_answer(query, scopes)
      :escalate -> escalate_answer(query, scopes, opts)
    end
  end

  @doc """
  Scope-filtered retrieval over the graph (default-deny). Matches significant
  query terms against node identity keys. Performance: one indexed `ILIKE ANY`
  query, bounded by `:limit`.
  """
  @spec search(String.t(), [String.t()], keyword()) :: [hit()]
  def search(_query, [], _opts), do: []

  def search(query, scopes, opts) do
    limit = Keyword.get(opts, :limit, @search_limit)

    case patterns(query) do
      [] ->
        []

      pats ->
        sql = """
        SELECT id, type, key FROM node
        WHERE scope = ANY($1) AND key ILIKE ANY($2)
        ORDER BY key LIMIT $3
        """

        %{rows: rows} = Repo.query!(sql, [scopes, pats, limit])
        Enum.map(rows, fn [id, type, key] -> %{id: id, type: type, key: key, score: 1.0} end)
    end
  end

  @doc "Knowledge-base health: graph size + embedding-namespace stamps (ADR-6)."
  @spec status() :: %{nodes: integer(), edges: integer(), namespaces: [map()]}
  def status do
    %{rows: [[nodes]]} = Repo.query!("SELECT count(*) FROM node")
    %{rows: [[edges]]} = Repo.query!("SELECT count(*) FROM edge")

    %{rows: ns} =
      Repo.query!("SELECT namespace, model, dim, status FROM schema_meta ORDER BY namespace")

    %{
      nodes: nodes,
      edges: edges,
      namespaces:
        Enum.map(ns, fn [n, m, d, s] -> %{namespace: n, model: m, dim: d, status: s} end)
    }
  end

  # --- tiers ---------------------------------------------------------------

  defp greeting do
    %{
      answer: "Hello — ask me about the knowledge base.",
      confidence: 0.9,
      tier: "tier0",
      citations: []
    }
  end

  defp tools_answer(query, scopes) do
    case search(query, scopes, limit: @search_limit) do
      [] ->
        %{
          answer: "I found nothing in the knowledge base for that.",
          confidence: 0.3,
          tier: "tier_tools",
          citations: []
        }

      hits ->
        %{
          answer: "Found #{length(hits)} matching item(s) in the knowledge base.",
          confidence: 0.7,
          tier: "tier_tools",
          citations: Enum.map(hits, &cite/1)
        }
    end
  end

  defp escalate_answer(query, scopes, opts) do
    hits = search(query, scopes, limit: @search_limit)
    grounding = Enum.map_join(hits, "\n", fn h -> "- #{h.type}: #{h.key}" end)

    case Consilium.deliberate(query, Keyword.put(opts, :grounding, grounding)) do
      {:ok, verdict} ->
        %{
          answer: verdict.answer,
          confidence: verdict.confidence,
          tier: "escalate",
          citations: Enum.map(hits, &cite/1)
        }

      {:error, _reason} ->
        # Fail-loud: quarantine as low confidence, never emit raw panel text.
        %{
          answer: "I could not produce a confident answer.",
          confidence: 0.0,
          tier: "escalate",
          citations: []
        }
    end
  end

  defp cite(hit), do: %{source: hit.type, ref: hit.key, confidence: hit.score}

  # Significant query terms → ILIKE patterns (drop stopwords and short tokens).
  @spec patterns(String.t()) :: [String.t()]
  defp patterns(query) do
    query
    |> String.downcase()
    |> String.split(~r/\W+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or &1 in @stopwords))
    |> Enum.uniq()
    |> Enum.map(&"%#{&1}%")
  end
end
