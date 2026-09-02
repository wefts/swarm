defmodule Swarm.ConversationContradictions do
  @moduledoc """
  Deterministic cross-turn contradiction detection for recent assistant answers.

  This is deliberately narrow: it only catches recommendation/capability
  polarity flips ("avoid/lacks X" versus "use/recommend/provides X") for
  repeated named terms. It is not a truth judge and does not grade the new
  answer; it makes a visible correction when the new supported answer conflicts
  with something the assistant already told the same conversation.
  """

  @type message :: %{role: String.t(), body: String.t()}
  @type conflict :: %{
          term: String.t(),
          prior: :recommend | :avoid,
          current: :recommend | :avoid
        }

  @negative ~r/\b(?:avoid|do not use|don't use|should not use|not recommended|discouraged|lack|lacks|lacking|does not provide|do not provide|doesn't provide|do not use|does not use)\b/i
  @positive ~r/\b(?:recommended|recommend|should use|use|standard|preferred|provide|provides|providing|has|have)\b/i

  @doc """
  Prefix a correction when a new answer reverses recommendation polarity from a
  prior assistant message in the same authorized conversation.
  """
  @spec maybe_annotate(map(), [message()]) :: map()
  def maybe_annotate(%{status: :found, answer: answer} = result, messages)
      when is_binary(answer) and is_list(messages) do
    case detect(messages, answer) do
      nil ->
        result

      conflict ->
        Map.update!(result, :answer, &prefix_correction(&1, conflict))
    end
  end

  def maybe_annotate(result, _messages), do: result

  @doc "Return the first narrow polarity conflict, or nil."
  @spec detect([message()], String.t()) :: conflict() | nil
  def detect(messages, answer) when is_list(messages) and is_binary(answer) do
    prior_claims =
      messages
      |> Enum.filter(&(Map.get(&1, :role) == "assistant"))
      |> Enum.flat_map(&claims(Map.get(&1, :body, "")))

    current_claims = claims(answer)

    Enum.find_value(prior_claims, fn prior ->
      Enum.find_value(current_claims, fn current ->
        if prior.polarity != current.polarity and same_term?(prior.term, current.term) do
          %{
            term: display_term(prior.term, current.term),
            prior: prior.polarity,
            current: current.polarity
          }
        end
      end)
    end)
  end

  defp prefix_correction(answer, %{term: term, prior: prior, current: current}) do
    "Correction: my earlier answer #{polarity_phrase(prior, term)}, but the current " <>
      "grounded answer #{polarity_phrase(current, term)}. The earlier answer was wrong.\n\n" <>
      answer
  end

  defp polarity_phrase(:avoid, term), do: "said to avoid #{term}"
  defp polarity_phrase(:recommend, term), do: "says to use or prefer #{term}"

  defp claims(text) do
    text
    |> split_sentences()
    |> Enum.flat_map(&split_clauses/1)
    |> Enum.flat_map(fn sentence ->
      polarity =
        cond do
          Regex.match?(@negative, sentence) -> :avoid
          Regex.match?(@positive, sentence) -> :recommend
          true -> nil
        end

      if polarity do
        sentence
        |> extract_terms()
        |> Enum.map(&%{polarity: polarity, term: &1})
      else
        []
      end
    end)
  end

  defp split_clauses(sentence), do: String.split(sentence, ~r/\s+(?:and|but)\s+|;/i, trim: true)

  defp split_sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp extract_terms(sentence) do
    (backtick_terms(sentence) ++ capitalized_terms(sentence) ++ runner_terms(sentence))
    |> Enum.flat_map(&split_compound/1)
    |> Enum.map(&normalize_term/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp backtick_terms(sentence) do
    Regex.scan(~r/`([^`]+)`/, sentence, capture: :all_but_first)
    |> List.flatten()
  end

  defp capitalized_terms(sentence) do
    Regex.scan(
      ~r/\b[A-Z][A-Za-z0-9_-]*(?:\/[A-Z][A-Za-z0-9_-]*)?(?:\s+[A-Z][A-Za-z0-9_-]*){0,3}\b/,
      sentence
    )
    |> List.flatten()
  end

  defp runner_terms(sentence) do
    Regex.scan(
      ~r/\b([A-Za-z0-9_-]+(?:\/[A-Za-z0-9_-]+)?(?:\s+[A-Za-z0-9_-]+){0,2}\s+runners?)\b/i,
      sentence,
      capture: :all_but_first
    )
    |> List.flatten()
  end

  defp split_compound(term) do
    term
    |> String.split(~r/\s+(?:or|and)\s+|,|;/i, trim: true)
    |> Enum.flat_map(&String.split(&1, "/", trim: true))
  end

  defp normalize_term(term) do
    term
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_. -]/, "")
    |> String.replace(~r/^(?:avoid|use|the|a|an|recommended|prefer|preferred|standard)\s+/, "")
    |> String.replace(~r/\brunners\b/, "runner")
    |> String.trim()
  end

  defp same_term?(a, b) do
    a == b or
      (String.length(a) >= 4 and String.contains?(b, a)) or
      (String.length(b) >= 4 and String.contains?(a, b))
  end

  defp display_term(a, b), do: if(String.length(b) >= String.length(a), do: b, else: a)
end
