defmodule Swarm.Graph.ConfidenceTest do
  use ExUnit.Case, async: true

  alias Swarm.Graph.Confidence

  describe "chain/1 (AND)" do
    test "empty chain is certain" do
      assert Confidence.chain([]) == 1.0
    end

    test "product along the chain" do
      assert_in_delta Confidence.chain([0.5]), 0.5, 1.0e-9
      assert_in_delta Confidence.chain([0.5, 0.5]), 0.25, 1.0e-9
      assert_in_delta Confidence.chain([0.9, 0.8, 0.5]), 0.36, 1.0e-9
    end

    test "longer inference is monotonically less reliable" do
      assert Confidence.chain([0.9, 0.9]) > Confidence.chain([0.9, 0.9, 0.9])
    end
  end

  describe "noisy_or/1 (OR across independent evidence)" do
    test "no evidence is no confidence" do
      assert Confidence.noisy_or([]) == 0.0
    end

    test "combines independent probabilities" do
      assert_in_delta Confidence.noisy_or([0.5]), 0.5, 1.0e-9
      assert_in_delta Confidence.noisy_or([0.5, 0.5]), 0.75, 1.0e-9
    end

    test "more independent evidence only increases confidence (monotone)" do
      assert Confidence.noisy_or([0.5, 0.5]) > Confidence.noisy_or([0.5])
    end
  end

  describe "combine/1 (max within group, noisy-OR across groups)" do
    test "collapses correlated paths to their strongest, then noisy-ORs groups" do
      # group A best = 0.9, group B best = 0.5 → 1 - (1-0.9)(1-0.5) = 0.95
      assert_in_delta Confidence.combine([[0.2, 0.9], [0.5]]), 0.95, 1.0e-9
    end

    test "a shared-ancestor group does not double-count (max, not sum/noisy-OR)" do
      # two correlated paths at 0.6 collapse to 0.6, not 0.84
      assert_in_delta Confidence.combine([[0.6, 0.6]]), 0.6, 1.0e-9
    end

    test "empty is zero" do
      assert Confidence.combine([]) == 0.0
    end
  end
end
