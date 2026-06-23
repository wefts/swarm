defmodule Swarm.Coordination.StagnationTest do
  @moduledoc """
  T13 — the stagnation monitor. An unhandled change kind and a claimable trace
  nobody takes past its TTL are SURFACED (deduped), never a silent forever-stall.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Coordination.Stagnation
  alias Swarm.Repo
  alias Swarm.Stigmergy.Dispatch

  defp row(change, target),
    do: %{change: change, target_key: target, payload: %{}, idem_key: "#{change}:#{target}"}

  defp dispatcher do
    {:ok, d} = Dispatch.start_link(name: :"disp_#{System.unique_integer([:positive])}")
    d
  end

  test "an unhandled change kind is surfaced ONCE, deduped (no flood)" do
    d = dispatcher()
    :ok = Dispatch.subscribe("known", fn _ -> :ok end, d)

    # the same unhandled kind dispatched many times → a single surfaced row
    for i <- 1..5, do: Dispatch.dispatch(row("orphan", "edge:#{i}"), d)

    assert Stagnation.count() == 1
    assert [%{reason: "no_subscriber", ref: "orphan"}] = Stagnation.recent(1)
  end

  test "a matched row runs its handler and is NOT surfaced as stagnant" do
    test_pid = self()
    d = dispatcher()
    :ok = Dispatch.subscribe("known", fn _ -> send(test_pid, :handled) end, d)

    :ok = Dispatch.dispatch(row("known", "edge:2"), d)

    assert_receive :handled, 1_000
    assert Stagnation.count() == 0
  end

  test "scan_stalls surfaces an unclaimed coordination trace past its TTL, deduped" do
    old = add_node!(%{type: "task", scope: "public", kind: "coordination"})
    Repo.query!("UPDATE node SET created_at = now() - interval '1 hour' WHERE id = $1", [old])
    _fresh = add_node!(%{type: "task", scope: "public", kind: "coordination"})

    # the old one is unclaimed past 60s; the fresh one is not
    assert Stagnation.unclaimed(60) == [old]

    assert Stagnation.scan_stalls(60) == 1
    assert Stagnation.count() == 1
    assert [%{reason: "stalled_claim", ref: ref}] = Stagnation.recent(1)
    assert ref == to_string(old)

    # running again does not double-record (deduped)
    assert Stagnation.scan_stalls(60) == 1
    assert Stagnation.count() == 1
  end
end
