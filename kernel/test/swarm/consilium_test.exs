defmodule Swarm.ConsiliumTest do
  use ExUnit.Case, async: true

  alias Swarm.Consilium

  @judge_ok ~s({"answer": "synthesized", "confidence": 0.8})

  defp fleet(panel), do: %{panel: panel, judge: "judge-model"}
  defp emb_const, do: fn _text -> {:ok, [1.0, 0.0]} end

  # generator that returns the judge JSON for json-mode calls, else a panel answer
  defp gen(panel_fun, judge_fun) do
    fn model, _prompt, opts ->
      if Keyword.get(opts, :json), do: judge_fun.(model), else: panel_fun.(model)
    end
  end

  test "panel runs in parallel, not sequentially" do
    panel_fun = fn model ->
      Process.sleep(80)
      {:ok, "take from #{model}"}
    end

    generator = gen(panel_fun, fn _ -> {:ok, @judge_ok} end)

    t0 = System.monotonic_time(:millisecond)

    {:ok, verdict} =
      Consilium.deliberate("q",
        fleet: fleet(~w(m1 m2 m3 m4)),
        generator: generator,
        embedder: emb_const()
      )

    elapsed = System.monotonic_time(:millisecond) - t0

    # 4 × 80ms concurrent ≈ 80ms, not 320ms
    assert elapsed < 280
    assert length(verdict.panel) == 4
    assert verdict.judge == "judge-model"
  end

  test "disagreement is measured pre-synthesis (mean pairwise 1 - cosine)" do
    generator = gen(fn model -> {:ok, model} end, fn _ -> {:ok, @judge_ok} end)

    embedder = fn
      "m1" -> {:ok, [1.0, 0.0]}
      "m2" -> {:ok, [0.0, 1.0]}
    end

    {:ok, verdict} =
      Consilium.deliberate("q", fleet: fleet(~w(m1 m2)), generator: generator, embedder: embedder)

    assert_in_delta verdict.disagreement, 1.0, 1.0e-9
  end

  test "judge failure quarantines (typed error), never raw panel text" do
    generator = gen(fn _ -> {:ok, "panel"} end, fn _ -> {:ok, "not json at all"} end)

    assert {:error, {:judge_failed, :judge_invalid_output}} =
             Consilium.deliberate("q",
               fleet: fleet(~w(m1)),
               generator: generator,
               embedder: emb_const()
             )
  end

  test "invalid judge output is retried, then accepted" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    judge_fun = fn _model ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      if n == 0, do: {:ok, "garbage"}, else: {:ok, @judge_ok}
    end

    generator = gen(fn _ -> {:ok, "panel"} end, judge_fun)

    {:ok, verdict} =
      Consilium.deliberate("q", fleet: fleet(~w(m1)), generator: generator, embedder: emb_const())

    assert verdict.answer == "synthesized"
    assert verdict.confidence == 0.8
  end

  test "empty panel fails loud" do
    generator = gen(fn _ -> {:error, :down} end, fn _ -> {:ok, @judge_ok} end)

    assert {:error, :panel_empty} =
             Consilium.deliberate("q",
               fleet: fleet(~w(m1 m2)),
               generator: generator,
               embedder: emb_const()
             )
  end

  @tag :integration
  @tag timeout: 300_000
  test "real parallel panel + judge on the Spark fleet returns a grounded verdict" do
    grounding = "The project chose Postgres + pgvector as the storage engine after a spike."

    assert {:ok, verdict} =
             Consilium.deliberate(
               "Which storage engine did the project choose, and why?",
               grounding: grounding,
               fleet: %{panel: ["qwen3:8b", "qwen3:14b"], judge: "llama3.3:70b"}
             )

    assert is_binary(verdict.answer) and verdict.answer != ""
    assert verdict.confidence >= 0.0 and verdict.confidence <= 1.0
    assert verdict.disagreement >= 0.0
    assert verdict.panel != []
  end
end
