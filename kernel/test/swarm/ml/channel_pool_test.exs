defmodule Swarm.ML.ChannelPoolTest do
  @moduledoc """
  Hermetic tests for the long-lived ML channel pool. No live ML service: the
  pool's `connect_fun` is injected, returning fake channels whose `conn_pid` is a
  plain process we can kill to simulate a severed transport. The real gRPC
  keepalive / DNS / disconnect-avoidance is validated on the live stack (the
  card's "verify on real signal").
  """
  use ExUnit.Case, async: false

  alias Swarm.ML.Boundary
  alias Swarm.ML.ChannelPool

  # ── fake transport ──────────────────────────────────────────────────────────

  # A connect_fun that always succeeds, minting a fresh channel with a live
  # conn_pid each time. `tag` lets a test correlate channels with calls.
  defp ok_connect_fun do
    fn _addr, _opts -> {:ok, fake_channel()} end
  end

  defp failing_connect_fun do
    fn _addr, _opts -> {:error, :econnrefused} end
  end

  defp fake_channel do
    conn = spawn(fn -> Process.sleep(:infinity) end)

    %GRPC.Channel{
      host: "fake-ml",
      port: 50_051,
      scheme: "http",
      ref: make_ref(),
      adapter: GRPC.Client.Adapters.Gun,
      adapter_payload: %{conn_pid: conn}
    }
  end

  defp start_pool!(opts) do
    base = [
      enabled: true,
      size: 2,
      keepalive_ms: 10_000,
      backoff_ms: 20,
      backoff_max_ms: 50
    ]

    Application.put_env(:swarm, :ml_pool, Keyword.merge(base, opts))
    on_exit(fn -> Application.delete_env(:swarm, :ml_pool) end)
    start_supervised!(ChannelPool)
  end

  @select [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]

  # Wait until at least `n` workers have advertised a live channel.
  defp wait_healthy(n, tries \\ 100) do
    healthy =
      ChannelPool.registry()
      |> Registry.select(@select)
      |> Enum.count(fn {_pid, ch} -> not is_nil(ch) end)

    cond do
      healthy >= n ->
        :ok

      tries == 0 ->
        flunk("only #{healthy}/#{n} channels became healthy")

      true ->
        Process.sleep(10)
        wait_healthy(n, tries - 1)
    end
  end

  defp wait_until_fresh_conn(stale, tries \\ 100) do
    case ChannelPool.checkout() do
      {:ok, %GRPC.Channel{adapter_payload: %{conn_pid: conn}}, _} when conn != stale ->
        conn

      _ when tries > 0 ->
        Process.sleep(10)
        wait_until_fresh_conn(stale, tries - 1)

      _ ->
        flunk("worker did not reconnect with a fresh channel")
    end
  end

  # ── checkout ────────────────────────────────────────────────────────────────

  describe "checkout/0" do
    test "hands out a live channel and round-robins across workers" do
      start_pool!(size: 3, connect_fun: ok_connect_fun())
      wait_healthy(3)

      pids =
        for _ <- 1..6 do
          assert {:ok, %GRPC.Channel{}, pid} = ChannelPool.checkout()
          pid
        end

      # Three distinct workers, each picked twice — even round-robin spread.
      assert pids |> Enum.uniq() |> length() == 3
      assert Enum.frequencies(pids) |> Map.values() |> Enum.all?(&(&1 == 2))
    end

    test "excludes given workers so a retry lands on a different channel" do
      start_pool!(size: 2, connect_fun: ok_connect_fun())
      wait_healthy(2)

      assert {:ok, _ch, first} = ChannelPool.checkout()
      assert {:ok, _ch, second} = ChannelPool.checkout([first])
      assert second != first
      # Both excluded → nothing eligible → fail-loud (not a re-pick of a tried one).
      assert {:error, :unavailable} = ChannelPool.checkout([first, second])
    end

    test "returns :unavailable (fail-loud) when no worker is healthy" do
      start_pool!(connect_fun: failing_connect_fun())
      # Workers never connect; give them a moment to attempt + register nil.
      Process.sleep(50)
      assert {:error, :unavailable} = ChannelPool.checkout()
    end
  end

  # ── self-healing ─────────────────────────────────────────────────────────────

  describe "worker self-healing" do
    test "a severed connection is dropped and reconnected with a fresh channel" do
      start_pool!(size: 1, connect_fun: ok_connect_fun())
      wait_healthy(1)

      assert {:ok, %GRPC.Channel{} = ch1, _pid} = ChannelPool.checkout()
      conn1 = ch1.adapter_payload.conn_pid

      # Kill the underlying transport: the worker (linked, trapping) reconnects
      # with a fresh channel. Poll until checkout hands out a different conn.
      Process.exit(conn1, :kill)
      conn2 = wait_until_fresh_conn(conn1)

      assert conn2 != conn1
      assert Process.alive?(conn2)
    end
  end

  # ── Boundary integration ─────────────────────────────────────────────────────

  describe "Boundary.with_channel/1" do
    test "runs the fun with a channel and returns its result" do
      start_pool!(connect_fun: ok_connect_fun())
      wait_healthy(2)

      assert {:ok, :result} = Boundary.with_channel(fn %GRPC.Channel{} -> {:ok, :result} end)
    end

    test "retries once on another channel after a transport failure" do
      start_pool!(connect_fun: ok_connect_fun())
      wait_healthy(2)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Boundary.with_channel(fn %GRPC.Channel{} ->
          n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
          if n == 1, do: {:error, {:rpc_failed, :boom}}, else: {:ok, :recovered}
        end)

      assert {:ok, :recovered} = result
      assert Agent.get(counter, & &1) == 2
    end

    test "a raised/exited RPC is treated as a transport failure and retried" do
      start_pool!(connect_fun: ok_connect_fun())
      wait_healthy(2)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Boundary.with_channel(fn %GRPC.Channel{} ->
          n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
          if n == 1, do: exit(:dead_conn), else: {:ok, :recovered}
        end)

      assert {:ok, :recovered} = result
      assert Agent.get(counter, & &1) == 2
    end

    test "fails loud when no channel is available" do
      start_pool!(connect_fun: failing_connect_fun())
      Process.sleep(50)

      assert {:error, {:ml_unavailable, :no_healthy_channel}} =
               Boundary.with_channel(fn _ -> {:ok, :never} end)
    end
  end
end
