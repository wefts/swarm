defmodule Swarm.Gate.BandsTest do
  use ExUnit.Case, async: true

  alias Swarm.Gate.Bands

  test "derive finds the lowest threshold meeting the precision floor" do
    labeled = [{0.30, false}, {0.40, false}, {0.80, true}, {0.90, true}]
    bands = Bands.derive(labeled, precision_floor: 0.9)
    # at 0.80 the kept set {0.80,0.90} is 100% correct; below it precision drops
    assert bands.handle == 0.80
  end

  test "classify splits handle vs escalate at the threshold" do
    bands = %Bands{handle: 0.677}
    assert Bands.classify(bands, 0.70) == :handle
    assert Bands.classify(bands, 0.677) == :handle
    assert Bands.classify(bands, 0.50) == :escalate
  end

  test "derivation is reproducible (same data → same threshold)" do
    labeled = [{0.1, false}, {0.6, true}, {0.7, true}, {0.2, false}]
    assert Bands.derive(labeled) == Bands.derive(labeled)
  end
end
