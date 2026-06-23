defmodule Swarm.LLM.BudgetTest do
  @moduledoc """
  T5 — per-escalation token budget (ADR-7). The ground-truth gate: a huge payload
  is refused BEFORE any model call, so the glpi 385k-token path is structurally
  impossible; per-escalation cost is visible in telemetry.
  """
  use ExUnit.Case, async: false

  alias Swarm.Consilium
  alias Swarm.LLM.Budget
  alias Swarm.ML.Generation

  describe "estimate + ensure" do
    test "estimate_tokens is bytes/4" do
      assert Budget.estimate_tokens(String.duplicate("a", 400)) == 100
    end

    test "within ceiling → :ok" do
      assert Budget.ensure("small", 1_000) == :ok
    end

    test "over ceiling → refused fail-loud with the numbers" do
      big = String.duplicate("x", 8_000)
      assert {:error, {:over_budget, est, 1_000}} = Budget.ensure(big, 1_000)
      assert est > 1_000
    end
  end

  describe "model-boundary backstop (ANY caller, not just consilium)" do
    test "Generation.generate refuses over the hard ceiling before any RPC" do
      # ~75k estimated tokens > 64k default; refused before Boundary.with_channel,
      # so this needs no running ML service.
      huge = String.duplicate("x", 300_000)
      assert {:error, {:over_budget, est, 64_000}} = Generation.generate("m", huge)
      assert est > 64_000
    end
  end

  describe "consilium enforces the ceiling before the model call" do
    setup do
      embedder = fn _ -> {:error, :skip} end
      %{embedder: embedder}
    end

    test "a huge grounding is refused and the model is NEVER called", %{embedder: embedder} do
      test_pid = self()
      # generator that screams if it is ever invoked
      gen = fn _m, _p, _o ->
        send(test_pid, :generator_called)
        {:ok, "should not happen"}
      end

      huge = String.duplicate("raw payload ", 50_000)

      assert {:error, {:over_budget, est, 32_000}} =
               Consilium.deliberate("q",
                 grounding: huge,
                 generator: gen,
                 embedder: embedder,
                 fleet: %{panel: ["m1"], judge: "j", token_ceiling: 32_000}
               )

      assert est > 32_000
      # the raw dump never reached a model — the 385k path is structurally impossible
      refute_received :generator_called
    end

    test "within budget → escalates and emits per-escalation cost telemetry", %{
      embedder: embedder
    } do
      gen = fn _model, _prompt, opts ->
        if Keyword.get(opts, :json),
          do: {:ok, ~s({"answer":"grounded answer","confidence":0.8})},
          else: {:ok, "panel take"}
      end

      handler = "budget-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        Budget.telemetry_event(),
        fn _e, meas, _meta, pid ->
          send(pid, {:cost, meas})
        end,
        self()
      )

      assert {:ok, v} =
               Consilium.deliberate("q",
                 grounding: "small grounding",
                 generator: gen,
                 embedder: embedder,
                 fleet: %{panel: ["m1"], judge: "j", token_ceiling: 32_000}
               )

      assert v.answer == "grounded answer"
      assert_received {:cost, %{tokens_in: ti, tokens_out: to}}
      assert ti > 0 and to > 0

      :telemetry.detach(handler)
    end
  end
end
