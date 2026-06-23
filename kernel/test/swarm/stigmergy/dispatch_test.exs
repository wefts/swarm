defmodule Swarm.Stigmergy.DispatchTest do
  @moduledoc """
  Step 4: the tailer dispatches each consumed row to the workers subscribed to its
  `change` kind; unrelated workers don't fire; redelivery converges via idem_key.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Stigmergy.{Dispatch, Tailer}

  setup do
    start_supervised!(Dispatch)

    {:ok, t} =
      Tailer.start_link(name: nil, handler: &Dispatch.dispatch/1, poll_ms: 60_000, gap_ms: 0)

    on_exit(fn -> if Process.alive?(t), do: GenServer.stop(t) end)
    %{tailer: t}
  end

  test "delivers to interested handlers only", %{tailer: t} do
    me = self()
    Dispatch.subscribe("node_added", fn row -> send(me, {:fired, row.change}) end)

    a = add_node!(%{type: "file"})
    b = add_node!(%{type: "concept"})
    {:ok, _} = Store.add_edge(a, b, "mentions", "ev-1")
    :ok = Tailer.drain(t)

    assert_receive {:fired, "node_added"}
    assert_receive {:fired, "node_added"}
    # edge_reinforced has no subscriber → never delivered.
    refute_receive {:fired, "edge_reinforced"}, 50
  end

  test "at-least-once delivery: an idempotent handler converges on idem_key" do
    me = self()
    {:ok, seen} = Agent.start_link(fn -> MapSet.new() end)

    Dispatch.subscribe("node_added", fn row ->
      fresh? =
        Agent.get_and_update(seen, fn s ->
          {not MapSet.member?(s, row.idem_key), MapSet.put(s, row.idem_key)}
        end)

      if fresh?, do: send(me, {:effect, row.idem_key})
    end)

    row = %{seq: 1, change: "node_added", target_key: "node:1", payload: %{}, idem_key: "node:1"}
    :ok = Dispatch.dispatch(row)
    # Redelivery (e.g. tailer restart before the cursor committed).
    :ok = Dispatch.dispatch(row)

    assert_receive {:effect, "node:1"}
    refute_receive {:effect, "node:1"}, 50
  end
end
