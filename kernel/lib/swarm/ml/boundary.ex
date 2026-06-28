defmodule Swarm.ML.Boundary do
  @moduledoc """
  Shared transport for the kernel↔Python ML boundary.

  Centralizes how `Swarm.ML.Embeddings` and `Swarm.ML.Generation` reach the
  Python ML pillar so they stay focused on their RPC.

  It runs RPCs over a pool of **long-lived** channels (`Swarm.ML.ChannelPool`)
  rather than a per-call connect → run → disconnect. The old per-call dance
  tripped grpc 0.11.5's crashing `:disconnect` handler, which poisoned the next
  connect with `:noproc` and took embeddings — and therefore every retrieval
  `Ask` — down (workspace decision 2026-06-28). The pool never disconnects.

  Resilience that lives here:

  - **Checkout → run → report.** A channel is picked round-robin; the RPC runs
    in the *caller's* process (HTTP/2 multiplexing preserved). A transport
    failure evicts that worker and is retried **once** on another channel.
  - **Fail loud.** When no healthy channel exists, callers get a clear
    `{:error, {:ml_unavailable, :no_healthy_channel}}` — never a silent hang or
    an opaque `:noproc`. Channel checkout is a retrieval dependency; its absence
    is surfaced, not masked.
  """
  require Logger

  alias Swarm.ML.ChannelPool

  @max_attempts 2

  @typedoc "An ML RPC failed because the transport (not the model) misbehaved."
  @type transport_error ::
          {:error, {:ml_unavailable, term()}} | {:error, {:rpc_failed, term()}}

  @doc """
  Check out a healthy ML channel, run `fun` with it, and return its result.

  On a transport failure (RPC error, dead connection, raised/exited call) the
  worker is evicted and `fun` is retried once on another channel. Returns
  whatever `fun` returns (e.g. `{:ok, _}` / `{:error, _}`), or
  `{:error, {:ml_unavailable, reason}}` when no channel is healthy.
  """
  @spec with_channel((GRPC.Channel.t() -> result)) :: result | transport_error()
        when result: term()
  def with_channel(fun) when is_function(fun, 1), do: run(fun, 1, [])

  # `tried` are the workers already evicted this call, excluded from re-selection
  # so the retry lands on a *different* channel.
  defp run(fun, attempt, tried) do
    case ChannelPool.checkout(tried) do
      {:ok, channel, worker} -> dispatch(fun, attempt, channel, worker, tried)
      {:error, :unavailable} -> {:error, {:ml_unavailable, :no_healthy_channel}}
    end
  end

  defp dispatch(fun, attempt, channel, worker, tried) do
    result = safe_run(fun, channel)

    cond do
      not transport_failure?(result) ->
        result

      attempt < @max_attempts ->
        ChannelPool.Worker.mark_dead(worker)
        Logger.debug("ML boundary transport failure, retry #{attempt + 1}/#{@max_attempts}")
        run(fun, attempt + 1, [worker | tried])

      true ->
        # Last attempt also failed at the transport — evict the bad worker and
        # surface the error so the caller sees an honest failure, not a hang.
        ChannelPool.Worker.mark_dead(worker)
        result
    end
  end

  # The RPC can return {:error, _} or, against a freshly-dead connection, raise
  # or exit in gun. Normalize all three into a typed transport error so a dead
  # channel triggers eviction + retry instead of crashing the caller.
  defp safe_run(fun, channel) do
    fun.(channel)
  rescue
    e -> {:error, {:rpc_failed, {:exception, e}}}
  catch
    kind, reason -> {:error, {:rpc_failed, {kind, reason}}}
  end

  defp transport_failure?({:error, {:rpc_failed, _}}), do: true
  defp transport_failure?({:error, {:connect_failed, _}}), do: true
  defp transport_failure?({:error, {:ml_unavailable, _}}), do: true
  defp transport_failure?(_), do: false
end
