defmodule Swarm.ML.ChannelPool.Manager do
  @moduledoc """
  Routes `checkout/0` requests across the pool's healthy workers.

  Holds only a round-robin cursor — the channels themselves live in their
  workers and are advertised through the pool Registry (a worker publishes its
  channel when connected, `nil` when not). Checkout reads the currently-healthy
  set from the Registry, so workers that are reconnecting are skipped
  automatically, and fail-loud (`{:error, :unavailable}`) falls out naturally
  when none are healthy.

  Picking does NOT lock a channel: callers run their RPC concurrently over the
  shared channel (HTTP/2 multiplexes), so a slow generation call never starves
  embeddings. Round-robin just spreads load across replicas evenly.
  """
  use GenServer

  alias Swarm.ML.ChannelPool

  # Match every worker entry → {pid, channel}; checkout filters out nil channels.
  @select [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Pick a healthy channel round-robin, skipping any worker in `exclude`.

  `exclude` carries the worker(s) a caller already saw fail this attempt, so the
  one retry lands on a *different* channel (the decision's "retry once on another
  worker") — not on the just-evicted one before it has finished reconnecting.

  Returns `{:ok, channel, worker_pid}` (the pid so a caller can `mark_dead/1`
  after a transport failure) or `{:error, :unavailable}` when no eligible worker
  has a live channel.
  """
  @spec checkout([pid()]) :: {:ok, GRPC.Channel.t(), pid()} | {:error, :unavailable}
  def checkout(exclude \\ []) do
    GenServer.call(__MODULE__, {:checkout, exclude})
  catch
    # No pool running (e.g. an operator script that didn't start it) — treat as
    # unavailable so callers fail loud rather than crashing on :noproc.
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(:ok), do: {:ok, 0}

  @impl true
  def handle_call({:checkout, exclude}, _from, cursor) do
    case healthy(exclude) do
      [] ->
        {:reply, {:error, :unavailable}, cursor}

      workers ->
        {pid, channel} = Enum.at(workers, rem(cursor, length(workers)))
        {:reply, {:ok, channel, pid}, cursor + 1}
    end
  end

  defp healthy(exclude) do
    ChannelPool.registry()
    |> Registry.select(@select)
    |> Enum.filter(fn {pid, channel} -> not is_nil(channel) and pid not in exclude end)
  end
end
