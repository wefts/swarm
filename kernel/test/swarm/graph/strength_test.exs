defmodule Swarm.Graph.StrengthTest do
  use ExUnit.Case, async: true

  alias Swarm.Graph.Strength

  describe "saturation/1 (Hill f(n))" do
    test "zero detections is zero strength" do
      assert Strength.saturation(0) == 0.0
    end

    test "monotonically increasing in seen_count" do
      assert Strength.saturation(1) < Strength.saturation(5)
      assert Strength.saturation(5) < Strength.saturation(50)
    end

    test "saturates below 1.0 (no immortal edges)" do
      assert Strength.saturation(10_000) < 1.0
      # diminishing returns: each decade adds less
      d1 = Strength.saturation(10) - Strength.saturation(1)
      d2 = Strength.saturation(100) - Strength.saturation(10)
      assert d2 < d1
    end
  end

  describe "decay/1" do
    test "no decay at age 0" do
      assert Strength.decay(0) == 1.0
    end

    test "monotonically decreasing with age, staying positive" do
      day = 86_400
      assert Strength.decay(day) < 1.0
      assert Strength.decay(10 * day) < Strength.decay(day)
      assert Strength.decay(1000 * day) > 0.0
    end
  end

  describe "strength/2 and decayed_reliability/2" do
    test "strength is saturation times decay" do
      assert_in_delta Strength.strength(5, 0), Strength.saturation(5), 1.0e-12
      assert Strength.strength(5, 86_400) < Strength.strength(5, 0)
    end

    test "decayed_reliability absorbs time into r_0" do
      assert_in_delta Strength.decayed_reliability(0.8, 0), 0.8, 1.0e-12
      assert Strength.decayed_reliability(0.8, 86_400) < 0.8
    end
  end
end
