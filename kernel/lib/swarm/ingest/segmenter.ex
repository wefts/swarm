defmodule Swarm.Ingest.Segmenter do
  @moduledoc """
  Prose segmenter (swarm ADR-14 §2 stage 5, the Phase-1 default). Partitions a
  body into ordered windows whose approximate token count stays within a budget
  (≤ bge-m3's 8192 hard limit; the default is much smaller for retrieval
  granularity). Deterministic, no LLM, no network — it runs on the continuous
  ingest path.

  Strategy: pack whole paragraphs greedily into a window until the next paragraph
  would overflow the budget; a single paragraph larger than the budget is split on
  sentence boundaries, and a single sentence larger than the budget is hard-split
  on word boundaries (never mid-word). Token count is approximated by whitespace
  word count — cheap and good enough for windowing and the `token_count` column;
  the authoritative count is the embedder's, which never sees an over-budget
  window because the budget sits safely under the model limit.

  Source-adapted segmenters (HTML/table/code) are Phase 2; only the *contract*
  (ordered partitions ≤ budget) is kernel-owned, so they slot in behind this.
  """

  @doc "Segmenter identity stamped onto `content.segmenter` and used in tests."
  @spec name() :: String.t()
  def name, do: "prose-v1"

  @doc """
  Segment `body` into an ordered, non-empty list of windows, each within the
  token budget. `opts[:max_tokens]` overrides the configured default. An empty or
  whitespace-only body yields `[]`.
  """
  @spec segment(String.t(), keyword()) :: [String.t()]
  def segment(body, opts \\ []) when is_binary(body) do
    budget = Keyword.get(opts, :max_tokens, max_tokens())

    body
    |> paragraphs()
    |> Enum.flat_map(&fit(&1, budget))
    |> pack(budget)
  end

  @doc "Approximate token count of a string (whitespace word count)."
  @spec token_count(String.t()) :: non_neg_integer()
  def token_count(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  # Configured default window budget (well under the bge-m3 8192 ceiling).
  defp max_tokens do
    Application.get_env(:swarm, :ingest, [])
    |> Keyword.get(:segmenter, [])
    |> Keyword.get(:max_tokens, 400)
  end

  # Split on blank lines into paragraphs, dropping empties.
  defp paragraphs(body) do
    body
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # A paragraph within budget passes through; an over-budget one is broken down
  # to sentence- then word-sized pieces so nothing exceeds the budget.
  defp fit(para, budget) do
    if token_count(para) <= budget, do: [para], else: split_oversized(para, budget)
  end

  defp split_oversized(para, budget) do
    para
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.flat_map(fn sentence ->
      if token_count(sentence) <= budget, do: [sentence], else: hard_split(sentence, budget)
    end)
  end

  # Last resort: pack words up to the budget (never splits a word).
  defp hard_split(sentence, budget) do
    sentence
    |> String.split(~r/\s+/, trim: true)
    |> Enum.chunk_every(budget)
    |> Enum.map(&Enum.join(&1, " "))
  end

  # Greedily pack the (already within-budget) pieces into the fewest windows that
  # each stay within budget; preserves order.
  defp pack(pieces, budget) do
    {windows, current, _used} =
      Enum.reduce(pieces, {[], [], 0}, fn piece, {windows, current, used} ->
        n = token_count(piece)

        if current != [] and used + n > budget do
          {[finish(current) | windows], [piece], n}
        else
          {windows, [piece | current], used + n}
        end
      end)

    finished = if current == [], do: windows, else: [finish(current) | windows]
    Enum.reverse(finished)
  end

  defp finish(current), do: current |> Enum.reverse() |> Enum.join("\n\n")
end
