defmodule Swarm.Stigmergy.PartitionTest do
  @moduledoc """
  Step 5: partition-by-key lanes. Rows for the same `target_key` are processed in
  order on one lane; different keys run in parallel.
  """
  use ExUnit.Case, async: false

  alias Swarm.Stigmergy.Dispatch

  setup do
    start_supervised!(Dispatch)
    :ok
  end

  defp row(key, idem),
    do: %{seq: 1, change: "node_added", target_key: key, payload: %{}, idem_key: idem}

  test "different target_keys run in parallel" do
    me = self()

    Dispatch.subscribe("node_added", fn r ->
      send(me, {:started, r.target_key, self()})
      receive do: (:go -> :ok)
      send(me, {:finished, r.target_key})
    end)

    :ok = Dispatch.dispatch(row("node:A", "a"))
    :ok = Dispatch.dispatch(row("node:B", "b"))

    # Both lanes start while both handlers are still blocked → genuine parallelism.
    assert_receive {:started, "node:A", lane_a}
    assert_receive {:started, "node:B", lane_b}
    assert lane_a != lane_b

    send(lane_a, :go)
    send(lane_b, :go)
    assert_receive {:finished, "node:A"}
    assert_receive {:finished, "node:B"}
  end

  test "same target_key is processed strictly in order" do
    me = self()
    Dispatch.subscribe("node_added", fn r -> send(me, {:seen, r.idem_key}) end)

    :ok = Dispatch.dispatch(row("node:A", "a1"))
    :ok = Dispatch.dispatch(row("node:A", "a2"))
    :ok = Dispatch.dispatch(row("node:A", "a3"))

    assert_receive {:seen, "a1"}
    assert_receive {:seen, "a2"}
    assert_receive {:seen, "a3"}
  end
end
