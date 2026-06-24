defmodule Swarm.Ingest.SegmenterTest do
  @moduledoc """
  The prose segmenter (swarm ADR-14 §2 stage 5): ordered partitions, each within
  the token budget, covering the whole body — the contract Phase-2 source-adapted
  segmenters must also satisfy.
  """
  use ExUnit.Case, async: true

  alias Swarm.Ingest.Segmenter

  test "an empty or whitespace body yields no windows" do
    assert Segmenter.segment("") == []
    assert Segmenter.segment("   \n\n  ") == []
  end

  test "a short body is a single window" do
    assert Segmenter.segment("one small paragraph", max_tokens: 50) == ["one small paragraph"]
  end

  test "small paragraphs pack into windows that each stay within budget" do
    body = Enum.map_join(1..6, "\n\n", fn i -> "para #{i} has four tokens" end)
    windows = Segmenter.segment(body, max_tokens: 10)

    assert length(windows) > 1
    assert Enum.all?(windows, &(Segmenter.token_count(&1) <= 10))
  end

  test "an oversized paragraph is split on sentence then word boundaries, never mid-word" do
    long =
      Enum.map_join(1..40, " ", &"word#{&1}") <>
        ". " <> Enum.map_join(1..40, " ", &"tail#{&1}") <> "."

    windows = Segmenter.segment(long, max_tokens: 15)

    assert Enum.all?(windows, &(Segmenter.token_count(&1) <= 15))
    # no window splits a token: every emitted token appears whole in the source
    emitted = windows |> Enum.join(" ") |> String.split(~r/\s+/, trim: true)
    assert Enum.all?(emitted, &String.match?(&1, ~r/^(word|tail)\d+\.?$/))
  end

  test "ordering and coverage: concatenated windows preserve the token sequence" do
    body = "alpha beta\n\ngamma delta\n\nepsilon zeta"
    windows = Segmenter.segment(body, max_tokens: 3)

    seq = windows |> Enum.join(" ") |> String.split(~r/\s+/, trim: true)
    assert seq == ~w(alpha beta gamma delta epsilon zeta)
  end
end
