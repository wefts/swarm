defmodule Swarm.Graph.CoordinationTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Coordination

  describe "claim/4 — fenced CAS" do
    test "claims with a higher token, rejects a stale one" do
      id = add_node!(%{type: "task"})

      assert {:ok, 5} = Coordination.claim(id, "w1", 5)
      assert {:error, :stale} = Coordination.claim(id, "w2", 3)
      assert {:error, :stale} = Coordination.claim(id, "w2", 5)
      assert {:ok, 9} = Coordination.claim(id, "w2", 9)
      assert Coordination.read_fences([id]) == %{id => 9}
    end
  end

  describe "renew_lease/5 — CAS on observed lease_until" do
    test "renews when still held, loses when the lease moved underneath" do
      id = add_node!(%{type: "task"})
      {:ok, 1} = Coordination.claim(id, "w1", 1)
      observed = lease_until(id)

      assert {:ok, renewed} = Coordination.renew_lease(id, "w1", 1, observed)
      assert DateTime.compare(renewed, observed) in [:gt, :eq]
      # the old observed value is now stale → CAS fails
      assert {:error, :lost} = Coordination.renew_lease(id, "w1", 1, observed)
    end
  end

  describe "concurrent claims (ADR-1/ADR-2 invariant)" do
    test "no double-claim, no lost update: final fence == max successful token" do
      tasks = for _ <- 1..50, do: add_node!(%{type: "task"})
      writers = 8
      attempts = 150
      # Global monotonic, unique token source shared by all writers.
      counter = :atomics.new(1, signed: false)

      local_maxes =
        1..writers
        |> Enum.map(fn w ->
          Task.async(fn -> hammer(tasks, attempts, counter, "w#{w}") end)
        end)
        |> Task.await_many(60_000)

      succ_max =
        Enum.reduce(local_maxes, %{}, fn m, acc ->
          Map.merge(acc, m, fn _k, a, b -> max(a, b) end)
        end)

      fences = Coordination.read_fences(tasks)

      violations =
        Enum.count(tasks, fn tid -> Map.get(fences, tid, 0) != Map.get(succ_max, tid, 0) end)

      assert violations == 0
    end
  end

  # One writer: many attempts on random tasks; track the max token it landed.
  defp hammer(tasks, attempts, counter, worker) do
    Enum.reduce(1..attempts, %{}, fn _, local_max ->
      tid = Enum.random(tasks)
      token = :atomics.add_get(counter, 1, 1)

      case Coordination.claim(tid, worker, token) do
        {:ok, _} -> Map.update(local_max, tid, token, &max(&1, token))
        {:error, :stale} -> local_max
      end
    end)
  end

  defp lease_until(id) do
    %{rows: [[lease_until]]} = Repo.query!("SELECT lease_until FROM node WHERE id = $1", [id])
    lease_until
  end
end
