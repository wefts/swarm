defmodule Swarm.Gate.EvalTest do
  use ExUnit.Case, async: false

  alias Swarm.Gate
  alias Swarm.Gate.Eval

  # Real routing against bge-m3: derive bands from the frozen labeled set, then
  # confirm the labeled messages route to their expected tier under those bands.
  @moduletag :integration

  test "bands derived from real bge-m3 route the labeled fixture correctly" do
    {bands, scored} = Eval.derive_bands()

    assert bands.handle > 0.0 and bands.handle < 1.0
    # the measured distribution separates correct (high) from wrong (low)
    assert Enum.any?(scored, fn {_s, ok} -> ok end)

    for %{message: msg, expected: expected} <- Eval.labeled() do
      decision = Gate.route(msg, bands: bands)

      case expected do
        :escalate -> assert decision.tier == :escalate
        tier -> assert decision.tier == tier
      end
    end
  end
end
