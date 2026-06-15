defmodule Swarm.GateTest do
  use ExUnit.Case, async: false

  alias Swarm.Gate
  alias Swarm.Gate.Telemetry

  # Hermetic 3-D embedder: two prototypes on orthogonal axes, messages placed
  # near an axis (handle) or off both (escalate). Keeps routing deterministic.
  @protos [
    %{intent: :greet, tier: :tier0, text: "A"},
    %{intent: :tool, tier: :tier_tools, text: "B"}
  ]

  defp embedder do
    fn
      "A" -> {:ok, [1.0, 0.0, 0.0]}
      "B" -> {:ok, [0.0, 1.0, 0.0]}
      "greet me" -> {:ok, [0.95, 0.05, 0.0]}
      "do the tool thing" -> {:ok, [0.05, 0.95, 0.0]}
      "off topic" -> {:ok, [0.0, 0.0, 1.0]}
      "boom" -> {:error, :embedder_down}
      _ -> {:ok, [0.0, 0.0, 1.0]}
    end
  end

  defp route(msg), do: Gate.route(msg, embedder: embedder(), prototypes: @protos)

  setup do
    Telemetry.reset()
    :ok
  end

  test "routes a near-prototype message to its cheap tier" do
    assert %{tier: :tier0, reason: :matched} = route("greet me")
    assert %{tier: :tier_tools, reason: :matched} = route("do the tool thing")
  end

  test "routes a low-confidence message to escalate (bias to escalate)" do
    assert %{tier: :escalate, reason: :low_confidence} = route("off topic")
  end

  test "degrades to keyword routing when the embedder is down" do
    assert %{tier: :tier0, reason: :degraded} =
             Gate.route("hello there", embedder: fn _ -> {:error, :down} end)

    assert %{tier: :escalate, reason: :degraded} =
             Gate.route("zzz", embedder: fn _ -> {:error, :down} end)
  end

  test "cost telemetry counts tiers and reports % handled" do
    route("greet me")
    route("do the tool thing")
    route("off topic")
    assert %{tier0: 1, tier_tools: 1, escalate: 1} = Telemetry.snapshot()
    assert_in_delta Telemetry.pct_handled(), 2 / 3, 1.0e-9
  end

  describe "verify_then_climb/1" do
    test "climbs on empty or self-declared inability" do
      assert Gate.verify_then_climb(nil) == :climb
      assert Gate.verify_then_climb("") == :climb
      assert Gate.verify_then_climb([]) == :climb
      assert Gate.verify_then_climb("I don't know how to answer that") == :climb
    end

    test "keeps a real answer" do
      assert Gate.verify_then_climb("the build passed at 12:01") == :keep
    end
  end
end
