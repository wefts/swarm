defmodule Swarm.WorldMap.Gate.WhoCalibrationTest do
  @moduledoc """
  The :who serve-path calibration harness (E1 go/no-go). Verifies the metric computation with an
  injected entail (no real model). `false_serve_rate` is the go/no-go gate; the real-model run is
  done out-of-band on staging before flipping `who_serve` on.
  """
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.Gate.WhoCalibration

  test "an entail that ALWAYS serves ⇒ false_serve_rate 1.0 (worst)" do
    r = WhoCalibration.score(entail_fun: fn _q, _g -> true end)
    assert r.false_serve_rate == 1.0
    assert r.serve_recall == 1.0
    assert length(r.false_serves) == Enum.count(WhoCalibration.labeled(), &(&1.serve == false))
  end

  test "an entail that ALWAYS vetoes ⇒ false_serve_rate 0.0 (safe, zero recall)" do
    r = WhoCalibration.score(entail_fun: fn _q, _g -> false end)
    assert r.false_serve_rate == 0.0
    assert r.serve_recall == 0.0
    assert r.false_serves == []
  end

  test "the labelled set is weighted toward should-VETO near-misses" do
    labels = WhoCalibration.labeled()
    assert Enum.count(labels, &(&1.serve == false)) >= Enum.count(labels, & &1.serve)
    assert Enum.count(labels, & &1.serve) >= 3
  end
end
