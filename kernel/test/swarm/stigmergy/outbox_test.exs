defmodule Swarm.Stigmergy.OutboxTest do
  @moduledoc """
  Step 1 of the stigmergy signal (swarm ADR-2 / docs/design/stigmergy-signal.md):
  graph writes append a transactional outbox row — atomic with the write, ordered
  by a monotonic `seq`, and only for real changes.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp outbox do
    %{rows: rows} =
      Repo.query!("SELECT seq, change, target_key, idem_key FROM outbox ORDER BY seq")

    Enum.map(rows, fn [seq, change, tkey, idem] ->
      %{seq: seq, change: change, target_key: tkey, idem_key: idem}
    end)
  end

  test "add_edge with new provenance appends exactly one ordered edge signal" do
    a = add_node!(%{type: "file"})
    b = add_node!(%{type: "concept"})
    before = outbox()

    assert {:ok, %{reinforced: true, id: edge_id}} = Store.add_edge(a, b, "mentions", "ev-1")

    new = Enum.drop(outbox(), length(before))
    assert [%{change: change, target_key: tkey, seq: seq}] = new
    assert change =~ "edge"
    assert tkey == "edge:#{edge_id}"
    # monotonic: the new seq is greater than every prior seq
    assert Enum.all?(before, fn r -> seq > r.seq end)
  end

  test "node writes emit node_added, strictly increasing seq" do
    _ = add_node!(%{type: "file"})
    _ = add_node!(%{type: "concept"})
    rows = outbox()
    node_seqs = rows |> Enum.filter(&(&1.change == "node_added")) |> Enum.map(& &1.seq)
    assert length(node_seqs) >= 2
    assert node_seqs == Enum.sort(node_seqs)
    assert length(Enum.uniq(node_seqs)) == length(node_seqs)
  end

  test "a rolled-back transaction leaves no outbox row (atomic)" do
    a = add_node!(%{type: "file"})
    b = add_node!(%{type: "concept"})
    before = length(outbox())

    assert {:error, :boom} =
             Repo.transaction(fn ->
               {:ok, _} = Store.add_edge(a, b, "links", "ev-x")
               Repo.rollback(:boom)
             end)

    assert length(outbox()) == before
  end

  test "duplicate provenance (no-op reinforcement) emits no new signal" do
    a = add_node!(%{type: "file"})
    b = add_node!(%{type: "concept"})
    {:ok, %{reinforced: true}} = Store.add_edge(a, b, "mentions", "ev-1")
    n = length(outbox())

    {:ok, %{reinforced: false}} = Store.add_edge(a, b, "mentions", "ev-1")
    assert length(outbox()) == n
  end
end
