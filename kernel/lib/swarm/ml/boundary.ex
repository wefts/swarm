defmodule Swarm.ML.Boundary do
  @moduledoc """
  Shared transport for the kernel↔Python ML boundary.

  Centralizes the connect → run → disconnect dance so `Swarm.ML.Embeddings` and
  `Swarm.ML.Generation` stay focused on their RPC.

  Two resilience concerns live here, not in the callers:

  - `GRPC.Stub.disconnect/1` can raise or exit (grpc 0.11.5) *after a successful
    call*, so disconnect is best-effort: a cleanup failure is logged and
    swallowed, never allowed to mask the RPC result.
  - The ML service is a horizontal pillar (replicated). Compose DNS round-robins
    `ml` across replicas and may route to one that is starting (not yet ready),
    or one that just died. A transient connect/RPC failure is therefore retried
    once: the next attempt resolves to a healthy replica. This is what makes
    replica HA real (see `hive/docker-compose.yml` ml `deploy.replicas`).
  """
  require Logger

  @max_attempts 2
  @retry_backoff_ms 150

  @doc """
  Connect to `address`, run `fun` with the channel, always disconnect, and retry
  once on a transient connect/RPC failure (replica starting or just gone).

  Returns whatever `fun` returns (e.g. `{:ok, _}` / `{:error, _}`), or
  `{:error, {:connect_failed, reason}}` if every attempt fails to connect.
  """
  @spec with_channel(String.t(), (GRPC.Channel.t() -> result)) ::
          result | {:error, {:connect_failed, term()}}
        when result: term()
  def with_channel(address, fun, attempt \\ 1) when is_function(fun, 1) do
    result =
      case GRPC.Stub.connect(address) do
        {:ok, channel} ->
          try do
            fun.(channel)
          after
            safe_disconnect(channel)
          end

        {:error, reason} ->
          {:error, {:connect_failed, reason}}
      end

    maybe_retry(result, address, fun, attempt)
  end

  # Retry once on a transient failure — a different replica answers next time.
  defp maybe_retry({:error, {kind, _}}, address, fun, attempt)
       when kind in [:connect_failed, :rpc_failed] and attempt < @max_attempts do
    Logger.debug("ML boundary #{kind}, retry #{attempt + 1}/#{@max_attempts}")
    Process.sleep(@retry_backoff_ms)
    with_channel(address, fun, attempt + 1)
  end

  defp maybe_retry(result, _address, _fun, _attempt), do: result

  defp safe_disconnect(channel) do
    GRPC.Stub.disconnect(channel)
  rescue
    e -> Logger.debug("ML boundary disconnect raised: #{inspect(e)}")
  catch
    kind, reason -> Logger.debug("ML boundary disconnect #{kind}: #{inspect(reason)}")
  end
end
