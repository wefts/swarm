defmodule Swarm.Stigmergy.TailerTest do
  @moduledoc """
  Step 2 of the stigmergy signal: the tailer consumes outbox rows in `seq` order
  past a durable cursor, and a restart resumes from the cursor (no re-processing).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Stigmergy.Tailer

  # A tailer whose handler forwards each row to this test process. Long poll so
  # consumption is driven deterministically via `Tailer.drain/1`.
  defp start_tailer! do
    me = self()
    {:ok, pid} = Tailer.start_link(name: nil, handler: &send(me, {:row, &1}), poll_ms: 60_000)
    pid
  end

  test "consumes graph-write signals in seq order" do
    t = start_tailer!()
    a = add_node!(%{type: "file"})
    b = add_node!(%{type: "concept"})
    {:ok, _} = Store.add_edge(a, b, "mentions", "ev-1")

    :ok = Tailer.drain(t)

    assert_receive {:row, %{seq: s1, change: "node_added"}}
    assert_receive {:row, %{seq: s2, change: "node_added"}}
    assert_receive {:row, %{seq: s3, change: "edge_reinforced", payload: payload}}
    assert s1 < s2 and s2 < s3
    assert payload["seen_count"] == 1
    refute_receive {:row, _}, 50
  end

  test "a restart resumes from the cursor — no re-processing" do
    t1 = start_tailer!()
    a = add_node!(%{type: "file"})
    :ok = Tailer.drain(t1)
    assert_receive {:row, %{seq: 1, change: "node_added"}}

    # Tailer goes away; a write lands while nothing is listening.
    GenServer.stop(t1)
    b = add_node!(%{type: "concept"})

    # A fresh tailer must pick up only the new row (seq 2), never re-emit seq 1.
    t2 = start_tailer!()
    :ok = Tailer.drain(t2)
    assert_receive {:row, %{seq: 2, change: "node_added"}}
    refute_receive {:row, %{seq: 1}}, 50

    assert is_integer(a) and is_integer(b)
  end
end
