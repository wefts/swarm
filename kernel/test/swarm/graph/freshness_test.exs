defmodule Swarm.Graph.FreshnessTest do
  @moduledoc "S2 freshness/time-decay (master plan). Pure functions — async."
  use ExUnit.Case, async: true

  alias Swarm.Graph.Freshness

  @day 86_400

  describe "class/1" do
    test "maps relations to freshness classes; unknown → configuration" do
      assert Freshness.class("contains") == :structural
      assert Freshness.class("has_address") == :configuration
      assert Freshness.class("has_private_address") == :configuration
      assert Freshness.class("has_public_address") == :configuration
      assert Freshness.class("has_outbound_ip_address") == :configuration
      assert Freshness.class("contained_by") == :structural
      assert Freshness.class("routes_for") == :structural
      assert Freshness.class("terminates_for") == :structural
      assert Freshness.class("is_a") == :identity
      assert Freshness.class("managed_by") == :configuration
      assert Freshness.class("totally_unknown_rel") == :configuration
    end
  end

  describe "decay_factor/2" do
    test "fresh (age 0) = 1.0; older decays" do
      assert Freshness.decay_factor(0, "contains") == 1.0
      assert Freshness.decay_factor(-5, "contains") == 1.0
      assert Freshness.decay_factor(10 * @day, "contains") < 1.0
    end

    test "at one half-life the factor ≈ 0.5 (class-specific)" do
      # configuration half-life = 30d, structural = 180d
      assert_in_delta Freshness.decay_factor(30 * @day, "has_address"), 0.5, 0.02
      assert_in_delta Freshness.decay_factor(180 * @day, "contains"), 0.5, 0.02
    end

    test "structural decays MUCH slower than operational (stable facts don't over-escalate)" do
      age = 30 * @day
      assert Freshness.decay_factor(age, "contains") > Freshness.decay_factor(age, "has_address")
    end
  end

  describe "effective_reliability/3 — conflict ranking (stale loses)" do
    test "a fresh lower-tier fact outranks a stale higher-tier one" do
      fresh_iac = Freshness.effective_reliability(0.85, 0, "has_address")
      # a 'live' 0.95 fact not re-seen for ~4 configuration half-lives
      stale_live = Freshness.effective_reliability(0.95, 120 * @day, "has_address")
      assert fresh_iac > stale_live
    end
  end

  describe "fresh?/2 — serve gate" do
    test "fresh within one half-life; stale beyond → not served (escalate)" do
      assert Freshness.fresh?(0, "has_address")
      assert Freshness.fresh?(2 * @day, "has_address")
      refute Freshness.fresh?(60 * @day, "has_address")
      # identity is near-immutable: even a year is still fresh
      assert Freshness.fresh?(365 * @day, "is_a")
    end
  end
end
