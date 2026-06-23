defmodule Swarm.Stigmergy.GapTest do
  @moduledoc """
  Step 3: monotonic seq + gap detection. A missing seq is in-flight (wait and
  re-read) until older than `gap_ms`, then rolled-back (skip). Nothing is dropped
  silently; nothing is processed out of order.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Repo
  alias Swarm.Stigmergy.Tailer

  # Insert an outbox row with an EXPLICIT seq, to build a controlled gap.
  defp put(seq) do
    Repo.query!(
      "INSERT INTO outbox (seq, change, target_key, payload, idem_key) VALUES ($1,'t','t','{}'::jsonb,$2)",
      [seq, "i#{seq}"]
    )
  end

  defp start_tailer!(opts) do
    me = self()

    {:ok, pid} =
      Tailer.start_link([name: nil, handler: &send(me, {:row, &1}), poll_ms: 60_000] ++ opts)

    pid
  end

  test "waits on an in-flight gap, then processes in order once it fills" do
    put(1)
    put(3)
    t = start_tailer!(gap_ms: 60_000)

    # 1 processed; 3 held back because seq 2 is (presumed) in flight.
    assert_receive {:row, %{seq: 1}}
    refute_receive {:row, %{seq: 3}}, 50

    put(2)
    :ok = Tailer.drain(t)
    assert_receive {:row, %{seq: 2}}
    assert_receive {:row, %{seq: 3}}
  end

  test "skips a rolled-back gap after the timeout" do
    put(1)
    put(3)
    # gap_ms: 0 → the gap is noted on the first pass, then expired on the next.
    t = start_tailer!(gap_ms: 0)

    assert_receive {:row, %{seq: 1}}
    refute_receive {:row, %{seq: 3}}, 50

    :ok = Tailer.drain(t)
    assert_receive {:row, %{seq: 3}}
  end
end
