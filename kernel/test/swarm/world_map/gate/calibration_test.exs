defmodule Swarm.WorldMap.Gate.CalibrationTest do
  @moduledoc """
  The tier-gate calibration harness (ADR-17 #2 go/no-go). Verifies the metric computation with
  an injected entail (no real model). `false_serve_rate` is the go/no-go gate.
  """
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.Gate.Calibration

  test "an entail that ALWAYS serves ⇒ false_serve_rate 1.0 (all near-misses served — worst)" do
    r = Calibration.score(entail_fun: fn _q, _g -> true end)
    assert r.false_serve_rate == 1.0
    assert r.serve_recall == 1.0
    assert length(r.false_serves) == Enum.count(Calibration.labeled(), &(&1.serve == false))
  end

  test "an entail that ALWAYS vetoes ⇒ false_serve_rate 0.0 (safe, but zero recall)" do
    r = Calibration.score(entail_fun: fn _q, _g -> false end)
    assert r.false_serve_rate == 0.0
    assert r.serve_recall == 0.0
    assert r.false_serves == []
  end

  test "the labelled set is weighted toward should-VETO near-misses (false-serve is the metric)" do
    labels = Calibration.labeled()
    assert Enum.count(labels, &(&1.serve == false)) >= Enum.count(labels, & &1.serve)
    assert Enum.count(labels, & &1.serve) >= 3
  end
end
