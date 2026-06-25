defmodule Swarm.Ingest.Segmenter do
  @moduledoc """
  Structure-aware segmenter (swarm ADR-14 §2 stage 5). Partitions a body into
  ordered windows whose approximate token count stays within a budget (≤ bge-m3's
  8192 hard limit; the default is much smaller for retrieval granularity).
  Deterministic, no LLM, no network — it runs on the continuous ingest path.

  ## The `swarm_markdown_v1` body contract

  Connectors emit a body in a **canonical Markdown profile** (their source-specific
  cleanup converts XHTML/wikitext → this profile; the kernel never learns the
  source). The segmenter parses ONLY these block constructs — anything else is
  treated as prose text, so an unknown dialect quirk degrades gracefully (it does
  not silently couple the kernel to a source):

  - **ATX heading** — a line starting with 1–6 `#` then a space. Starts a new
    section; prose is never packed across a heading.
  - **Fenced code** — from a ```` ``` ```` line to the next fence line. **Atomic**:
    one window, never split mid-block or merged with prose (a blank line inside the
    fence does not break it).
  - **Pipe table** — consecutive `| … |` lines. **Atomic** (a flattened table loses
    row/cell relationships).
  - **List / blockquote / paragraph** — prose; packed greedily to the budget.

  An atomic block (code/table) is prefixed with its section heading as a one-line
  breadcrumb so it stays findable; an atomic block larger than the budget falls back
  to a hard window split (atomicity lost only when unavoidable). Prose packing and
  oversize-prose splitting are unchanged from the prose-only predecessor, so a body
  with no Markdown structure segments exactly as before.

  Token count is approximated by whitespace word count — cheap and good enough for
  windowing and the `token_count` column; the budget sits safely under the model
  limit so the embedder never sees an over-budget window.
  """

  @doc "Segmenter identity stamped onto `content.segmenter` and used in tests."
  @spec name() :: String.t()
  def name, do: "structured-v1"

  @doc """
  Segment `body` into an ordered, non-empty list of windows, each within the
  token budget. `opts[:max_tokens]` overrides the configured default. An empty or
  whitespace-only body yields `[]`.
  """
  @spec segment(String.t(), keyword()) :: [String.t()]
  def segment(body, opts \\ []) when is_binary(body) do
    budget = Keyword.get(opts, :max_tokens, max_tokens())

    body
    |> blocks()
    |> chunk(budget)
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

  # --- swarm_markdown_v1 block parse -----------------------------------------

  @heading ~r/^\#{1,6}\s+\S/
  @fence ~r/^\s*```/
  @table_row ~r/^\s*\|.*\|\s*$/

  # Classify the body into an ordered list of typed blocks.
  @spec blocks(String.t()) :: [{:heading | :code | :table | :prose, String.t()}]
  defp blocks(body) do
    body |> String.split("\n") |> do_blocks([])
  end

  defp do_blocks([], acc), do: Enum.reverse(acc)

  defp do_blocks([line | rest], acc) do
    cond do
      fence?(line) ->
        {code, rest2} = take_until_fence(rest, [line])
        do_blocks(rest2, [{:code, Enum.join(code, "\n")} | acc])

      heading?(line) ->
        do_blocks(rest, [{:heading, String.trim_trailing(line)} | acc])

      table_row?(line) ->
        {tbl, rest2} = Enum.split_while([line | rest], &table_row?/1)
        do_blocks(rest2, [{:table, Enum.join(tbl, "\n")} | acc])

      blank?(line) ->
        do_blocks(rest, acc)

      true ->
        {para, rest2} = Enum.split_while([line | rest], &prose_line?/1)
        do_blocks(rest2, [{:prose, para |> Enum.join("\n") |> String.trim()} | acc])
    end
  end

  defp take_until_fence([], acc), do: {Enum.reverse(acc), []}

  defp take_until_fence([l | rest], acc) do
    if fence?(l), do: {Enum.reverse([l | acc]), rest}, else: take_until_fence(rest, [l | acc])
  end

  defp heading?(l), do: Regex.match?(@heading, l)
  defp fence?(l), do: Regex.match?(@fence, l)
  defp table_row?(l), do: Regex.match?(@table_row, l)
  defp blank?(l), do: String.trim(l) == ""
  defp prose_line?(l), do: not (blank?(l) or fence?(l) or heading?(l) or table_row?(l))

  # --- chunk: section-aware packing ------------------------------------------

  @spec chunk([{atom(), String.t()}], pos_integer()) :: [String.t()]
  defp chunk(blocks, budget) do
    {out, buf, heading} =
      Enum.reduce(blocks, {[], [], nil}, fn
        {:heading, h}, {out, buf, heading} ->
          {out ++ flush(buf, heading, budget), [], h}

        {:prose, p}, {out, buf, heading} ->
          {out, buf ++ [p], heading}

        {atomic, text}, {out, buf, heading} when atomic in [:code, :table] ->
          {out ++ flush(buf, heading, budget) ++ atomic_windows(text, heading, budget), [],
           heading}
      end)

    out ++ flush(buf, heading, budget)
  end

  # Pack the section's prose into windows within budget, then prefix each with the
  # section heading breadcrumb. Budget is reduced by the breadcrumb's tokens so a
  # prefixed window still fits.
  defp flush([], _heading, _budget), do: []

  defp flush(buf, heading, budget) do
    bud = inner_budget(heading, budget)

    buf
    |> Enum.flat_map(&fit(&1, bud))
    |> pack(bud)
    |> Enum.map(&prefix(&1, heading))
  end

  # An atomic block: emit as one breadcrumbed window if it fits; otherwise (a huge
  # table/code file) hard-split the raw text — atomicity lost only when unavoidable.
  defp atomic_windows(text, heading, budget) do
    if token_count(text) + heading_tokens(heading) <= budget do
      [prefix(text, heading)]
    else
      hard_split(text, budget)
    end
  end

  defp inner_budget(heading, budget), do: max(1, budget - heading_tokens(heading))
  defp heading_tokens(nil), do: 0
  defp heading_tokens(h), do: token_count(h) + 1

  defp prefix(window, nil), do: window
  defp prefix(window, heading), do: heading <> "\n\n" <> window

  # --- prose packing (unchanged contract) ------------------------------------

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

  defp hard_split(text, budget) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.chunk_every(budget)
    |> Enum.map(&Enum.join(&1, " "))
  end

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
