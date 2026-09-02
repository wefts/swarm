defmodule Swarm.Graph.DocumentKind do
  @moduledoc """
  Deterministic document-kind hints for retrieval ranking.

  These labels are not ontology truth and are never written to the graph. They are conservative
  query-time hints used to nudge ranked memories when the user's query clearly asks for a policy,
  procedure, incident, or reference document shape.
  """

  @type kind :: :policy | :procedure | :incident | :reference | :unknown

  @policy ~r/\b(policy|governance|approval|approved|terms|review|reviews|compliance|mandatory|must|allowed|prohibited)\b/i
  @procedure ~r/\b(has_step|how[-\s]?to|install|installation|configure|configuration|procedure|runbook|step\s+\d+|steps?|setup|upgrade|deploy)\b/i
  @incident ~r/\b(incident|outage|postmortem|post[-\s]?mortem|cri|sev[ -]?\d|root cause|remediation)\b/i
  @reference ~r/\b(reference|overview|what is known|known facts|inventory|catalog|catalogue|glossary|definition|faq)\b/i

  @policy_query ~r/\b(policy|governance|approval|approved|terms|review|compliance|allowed|prohibited)\b/i
  @procedure_query ~r/\b(how[-\s]?to|how do i|install|installation|configure|configuration|procedure|runbook|setup|steps?)\b/i
  @incident_query ~r/\b(incident|outage|postmortem|post[-\s]?mortem|cri|sev[ -]?\d|root cause)\b/i
  @reference_query ~r/\b(reference|what is known|known facts|what do we know|overview|definition)\b/i
  @title_stopwords MapSet.new(
                     ~w(the a an of to and or for with about how what which why who when where is are was were do does did can could should would related show find list recent get see me my our your this that these those at in on into by from про розкажи розкажіть щодо по у в на та і й)
                   )
  @title_min_matched_tokens 2
  @title_min_subject_tokens 3
  @title_min_coverage 0.8

  @doc "Classify a retrieved document-like node from title, body spans, and optional evidence."
  @spec classify(map()) :: kind()
  def classify(doc) when is_map(doc) do
    title = Map.get(doc, :title) || Map.get(doc, :key) || ""
    body = body_text(doc)
    evidence = Map.get(doc, :structural_evidence, [])

    cond do
      has_step_evidence?(evidence) or regex?(@procedure, title) or regex?(@procedure, body) ->
        :procedure

      regex?(@incident, title) or regex?(@incident, body) ->
        :incident

      regex?(@policy, title) or regex?(@policy, body) ->
        :policy

      regex?(@reference, title) or regex?(@reference, body) ->
        :reference

      true ->
        :unknown
    end
  end

  def classify(_), do: :unknown

  @doc "Infer the kind shape requested by a query, when it is explicit enough to use for reranking."
  @spec query_kind(String.t()) :: kind()
  def query_kind(query) when is_binary(query) do
    cond do
      regex?(@procedure_query, query) -> :procedure
      regex?(@incident_query, query) -> :incident
      regex?(@policy_query, query) -> :policy
      regex?(@reference_query, query) -> :reference
      true -> :unknown
    end
  end

  def query_kind(_), do: :unknown

  @doc """
  Return the high-confidence named-subject hit subset for `query`, or `[]`.

  The match is language-agnostic token coverage: after stopword removal, a hit title must have at
  least two title tokens present in the query, at least 80% title-token coverage, and those covered
  title tokens must appear in title order. This detects explicit title asks embedded in another
  language without hardcoding any corpus literal.
  """
  @spec named_subject_hits(String.t(), [map()]) :: [map()]
  def named_subject_hits(query, hits) when is_binary(query) and is_list(hits) do
    query_tokens = title_tokens(query)
    query_token_set = MapSet.new(query_tokens)

    hits
    |> Enum.filter(&named_subject_hit?(&1, query_tokens, query_token_set))
  end

  def named_subject_hits(_, _), do: []

  defp body_text(%{body: body}) when is_binary(body), do: body

  defp body_text(%{spans: spans}) when is_list(spans) do
    spans |> Enum.map(&Map.get(&1, :text, "")) |> Enum.join("\n")
  end

  defp body_text(_), do: ""

  defp has_step_evidence?(evidence) when is_list(evidence) do
    Enum.any?(evidence, fn
      "has_step" -> true
      %{relation: "has_step"} -> true
      %{type: "has_step"} -> true
      _ -> false
    end)
  end

  defp has_step_evidence?(_), do: false

  defp regex?(regex, text), do: Regex.match?(regex, text)

  defp named_subject_hit?(hit, query_tokens, query_token_set) do
    title_tokens = hit |> hit_title() |> title_tokens()

    if title_tokens == [] do
      false
    else
      matched = Enum.count(title_tokens, &MapSet.member?(query_token_set, &1))

      length(title_tokens) >= @title_min_subject_tokens and
        matched >= @title_min_matched_tokens and
        matched / length(title_tokens) >= @title_min_coverage and
        title_tokens_covered_in_order?(title_tokens, query_tokens, query_token_set)
    end
  end

  defp hit_title(hit) do
    Map.get(hit, :title) || Map.get(hit, "title") || Map.get(hit, :key) || Map.get(hit, "key") ||
      ""
  end

  defp title_tokens_covered_in_order?(title_tokens, query_tokens, query_token_set) do
    title_tokens
    |> Enum.filter(&MapSet.member?(query_token_set, &1))
    |> query_tokens_in_order?(query_tokens)
  end

  defp query_tokens_in_order?([], _query_tokens), do: true

  defp query_tokens_in_order?([wanted | rest], query_tokens) do
    case Enum.drop_while(query_tokens, &(&1 != wanted)) do
      [] -> false
      [_found | remaining] -> query_tokens_in_order?(rest, remaining)
    end
  end

  defp title_tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2 or MapSet.member?(@title_stopwords, &1)))
    |> Enum.uniq()
  end

  defp title_tokens(_), do: []
end
