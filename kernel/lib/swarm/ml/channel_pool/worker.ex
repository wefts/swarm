defmodule Swarm.ML.ChannelPool.Worker do
  @moduledoc """
  One pool worker owning a single **long-lived** gRPC channel to the Python ML
  pillar (`ml:50051`).

  Why a long-lived channel instead of the old connect → run → disconnect dance:
  grpc 0.11.5's `GRPC.Client.Connection` GenServer crashes with a
  `FunctionClauseError` while handling `:disconnect` (its `Enum.map` over
  `real_channels` only matches `{:ok, ch}` entries, not the `{:error, _}` /
  bare-channel shapes it actually stores). That crash leaves the connection
  supervisor inconsistent, so the *next* connect hits `:noproc` and every
  retrieval `Ask` fails. A worker that connects once and **never disconnects**
  sidesteps the buggy path entirely (workspace decision 2026-06-28).

  Resilience the worker owns:

  - **Independent DNS resolution → HA.** Each worker resolves `ml` afresh on
    every (re)connect; Docker DNS round-robins the replicas, so a pool spreads
    across them without us mapping channels to replicas by hand.
  - **Keepalive REQUIRED.** gun's HTTP/2 keepalive defaults to `:infinity`
    (off). Without it a half-open connection (a replica vanishing without a TCP
    RST) is invisible until a call blocks to its deadline. We enable PINGs so a
    dead channel surfaces promptly and self-heals.
  - **No silent gun retry.** `retry: 0` so a severed connection actually dies
    (the conn process is linked to us) → we drop the channel and reconnect with
    fresh DNS, landing on a surviving replica — rather than gun quietly papering
    over a dead replica.
  - **Reactive eviction.** A call that hits a transport failure tells its worker
    to `mark_dead/1`; the worker drops the channel (so `checkout` stops handing
    it out) and reconnects. The caller's one retry lands on another worker.

  The channel struct is plain data: callers run the RPC in their own process, so
  HTTP/2 multiplexing is preserved (a slow generation call does not block
  embeddings on the same channel).
  """
  use GenServer
  require Logger

  alias Swarm.ML.ChannelPool

  # ── public API ────────────────────────────────────────────────────────────

  @doc false
  def start_link({index, cfg}) do
    GenServer.start_link(__MODULE__, {index, cfg})
  end

  @doc """
  Evict this worker's channel after a transport failure and reconnect it.

  Synchronous so that by the time the caller retries `checkout/0` the dead
  channel is already out of rotation; the actual connection teardown + reconnect
  happen asynchronously afterwards so this stays off the hot path.
  """
  # Short timeout: handle_call(:mark_dead) is itself cheap, but the worker's
  # mailbox may be briefly busy reconnecting — never block the retrieval hot path
  # on it. A timeout still evicts (the call's effect) by the next checkout.
  @mark_dead_timeout_ms 1_000

  @spec mark_dead(pid()) :: :ok
  def mark_dead(pid) do
    GenServer.call(pid, :mark_dead, @mark_dead_timeout_ms)
  catch
    :exit, _ -> :ok
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init({index, cfg}) do
    Process.flag(:trap_exit, true)
    key = ChannelPool.worker_key(index)
    # Register up front (channel nil = not yet usable) so the worker is visible
    # to the pool the instant it exists; checkout skips nil-channel entries.
    {:ok, _} = Registry.register(ChannelPool.registry(), key, nil)

    state = %{
      index: index,
      key: key,
      cfg: cfg,
      channel: nil,
      conn_pid: nil,
      backoff: cfg.backoff_ms
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call(:mark_dead, _from, %{channel: nil} = state) do
    # Already evicted (a concurrent failure won the race) — nothing to do.
    {:reply, :ok, state}
  end

  def handle_call(:mark_dead, _from, %{channel: channel, conn_pid: conn_pid} = state) do
    # Unlink first so tearing the old connection down cannot deliver us a stray
    # EXIT that we'd mistake for a fresh failure.
    if is_pid(conn_pid), do: Process.unlink(conn_pid)
    publish(state.key, nil)
    send(self(), {:teardown_and_reconnect, channel, conn_pid})
    {:reply, :ok, %{state | channel: nil, conn_pid: nil}}
  end

  @impl true
  def handle_info({:teardown_and_reconnect, channel, conn_pid}, state) do
    teardown(channel, conn_pid)
    {:noreply, connect(state)}
  end

  def handle_info(:reconnect, state), do: {:noreply, connect(state)}

  # The live connection died on its own (replica gone, retry: 0). Drop it and
  # reconnect with fresh DNS → a surviving replica.
  def handle_info({:EXIT, pid, reason}, %{conn_pid: pid} = state) do
    Logger.warning("ML pool worker #{state.index} channel down: #{inspect(reason)}; reconnecting")
    publish(state.key, nil)
    {:noreply, connect(%{state | channel: nil, conn_pid: nil})}
  end

  # Our supervisor asking us to stop — propagate.
  def handle_info({:EXIT, _pid, :shutdown}, state), do: {:stop, :shutdown, state}

  # A stale connection we already unlinked + tore down — ignore.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ─────────────────────────────────────────────────────────────

  defp connect(%{cfg: cfg} = state) do
    case cfg.connect_fun.(cfg.address, connect_opts(cfg)) do
      {:ok, channel} ->
        conn_pid = channel.adapter_payload[:conn_pid]
        # Link the transport to us: a dead replica severs it → we hear about it.
        # (gun already links the opener; this is explicit + makes tests honest.)
        if is_pid(conn_pid), do: Process.link(conn_pid)
        publish(state.key, channel)
        Logger.debug("ML pool worker #{state.index} connected to #{cfg.address}")
        %{state | channel: channel, conn_pid: conn_pid, backoff: cfg.backoff_ms}

      {:error, reason} ->
        Logger.warning(
          "ML pool worker #{state.index} connect failed: #{inspect(reason)}; " <>
            "retry in #{state.backoff}ms"
        )

        Process.send_after(self(), :reconnect, jitter(state.backoff))
        %{state | channel: nil, conn_pid: nil, backoff: next_backoff(state.backoff, cfg)}
    end
  end

  # Long-lived channels NEVER take the buggy `GRPC.Stub.disconnect/1` path. We
  # reclaim the abandoned connection's resources directly instead: shut the gun
  # process and stop the (idle) Connection GenServer via a clean GenServer.stop,
  # whose no-op terminate avoids the crashing :disconnect handler.
  defp teardown(channel, conn_pid) do
    if is_pid(conn_pid) and Process.alive?(conn_pid), do: safe(fn -> :gun.shutdown(conn_pid) end)
    stop_connection(channel)
  end

  defp stop_connection(%{ref: ref}) when not is_nil(ref) do
    safe(fn -> GenServer.stop({:global, {GRPC.Client.Connection, ref}}, :normal, 1_000) end)
  end

  defp stop_connection(_), do: :ok

  defp publish(key, value) do
    Registry.update_value(ChannelPool.registry(), key, fn _ -> value end)
    :ok
  end

  defp connect_opts(cfg) do
    [adapter_opts: [retry: 0, http2_opts: %{keepalive: cfg.keepalive_ms}]]
  end

  defp next_backoff(current, cfg), do: min(current * 2, cfg.backoff_max_ms)

  # Spread reconnects so workers never retry in lockstep (no thundering herd on a
  # mass failure, e.g. both replicas bouncing): full jitter in [backoff, 1.5×).
  defp jitter(backoff), do: backoff + :rand.uniform(max(div(backoff, 2), 1))

  defp safe(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
