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

  # --- swarm_markdown_v1 structure-aware behaviour (Phase 2, Card 6) ----------

  test "name is the structured segmenter" do
    assert Segmenter.name() == "structured-v1"
  end

  test "headings start new sections — prose is NOT packed across a heading" do
    body = "# Alpha\n\nintro text here\n\n# Beta\n\nother text here"
    windows = Segmenter.segment(body, max_tokens: 500)

    assert length(windows) == 2
    [w1, w2] = windows
    assert w1 =~ "Alpha" and w1 =~ "intro text here"
    refute w1 =~ "Beta"
    assert w2 =~ "Beta" and w2 =~ "other text here"
  end

  test "a fenced code block is one atomic window, never merged with surrounding prose" do
    body = "# Setup\n\nrun this\n\n```bash\nmake build\n\nmake test\n```\n\nthen done"
    windows = Segmenter.segment(body, max_tokens: 500)

    code = Enum.find(windows, &(&1 =~ "make build"))
    assert code =~ "```"
    # blank line inside the fence does NOT split it
    assert code =~ "make build" and code =~ "make test"
    # the code window is not the same window as the prose around it
    refute code =~ "run this"
    refute code =~ "then done"
  end

  test "a pipe table is one atomic window, kept intact" do
    body = "# Data\n\nlead in\n\n| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n\ntrailer"
    windows = Segmenter.segment(body, max_tokens: 500)

    table = Enum.find(windows, &(&1 =~ "| 1 | 2 |"))
    assert table =~ "| a | b |" and table =~ "| 3 | 4 |"
    refute table =~ "lead in"
  end

  test "atomic code/table windows carry their section heading as context" do
    body = "# Deploy Runbook\n\n```\nkubectl apply\n```"
    [w] = Segmenter.segment(body, max_tokens: 500) |> Enum.filter(&(&1 =~ "kubectl"))
    assert w =~ "Deploy Runbook"
  end

  test "an oversized atomic block is hard-split but still kept off the prose" do
    big = "```\n" <> Enum.map_join(1..60, "\n", &"line#{&1} tok") <> "\n```"
    body = "# Big\n\nintro\n\n" <> big <> "\n\noutro"
    windows = Segmenter.segment(body, max_tokens: 20)

    assert Enum.all?(windows, &(Segmenter.token_count(&1) <= 20))
    code_windows = Enum.filter(windows, &(&1 =~ ~r/line\d+ tok/))
    assert length(code_windows) > 1
    assert Enum.all?(code_windows, &(not (&1 =~ "intro") and not (&1 =~ "outro")))
  end
end
