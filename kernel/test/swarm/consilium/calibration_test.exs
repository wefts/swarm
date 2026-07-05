defmodule Swarm.Consilium.CalibrationTest do
  @moduledoc """
  The judge `supported`-calibration harness (ADR-17 #1 Phase-2 gate). Verifies the METRIC
  computation with an injected generator (no real model) — the false-supported rate is the
  number that gates any judge change.
  """
  use ExUnit.Case, async: true

  alias Swarm.Consilium.Calibration

  defp gen(verdict_json), do: fn _model, _prompt, _opts -> {:ok, verdict_json} end
  defp fleet, do: %{judge: "test-judge", panel: [], token_ceiling: 32_000}

  test "a judge that ALWAYS says supported=true has false_supported_rate 1.0 (worst case)" do
    r =
      Calibration.score(
        fleet: fleet(),
        generator: gen(~s({"answer":"x","confidence":0.9,"supported":true}))
      )

    assert r.false_supported_rate == 1.0
    assert r.true_supported_recall == 1.0
    assert r.json_valid_rate == 1.0
    # every expected-false case is a miss
    assert length(r.misses) == Enum.count(Calibration.labeled(), &(&1.supported == false))
  end

  test "a judge that ALWAYS says supported=false has false_supported_rate 0.0 (safe, but no recall)" do
    r =
      Calibration.score(
        fleet: fleet(),
        generator: gen(~s({"answer":"x","confidence":0.5,"supported":false}))
      )

    assert r.false_supported_rate == 0.0
    assert r.true_supported_recall == 0.0
    assert r.misses == []
  end

  test "invalid JSON ⇒ all errors, json_valid_rate 0, and no false-supported (fail-closed)" do
    r = Calibration.score(fleet: fleet(), generator: gen("not json at all"))

    assert r.errors == r.n
    assert r.json_valid_rate == 0.0
    # a parse failure is NOT a supported=true — fail-closed keeps false-supported at 0
    assert r.false_supported_rate == 0.0
  end

  test "the labelled set is balanced enough to measure (has both true and false cases)" do
    labels = Calibration.labeled()
    assert Enum.count(labels, & &1.supported) >= 3
    assert Enum.count(labels, &(&1.supported == false)) >= 4
  end
end
