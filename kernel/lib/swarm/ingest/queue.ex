defmodule Swarm.Ingest.Queue do
  @moduledoc """
  Bounded ingestion queue with explicit backpressure (Domain 2). Events are
  buffered up to `:max_size`; once full, new events are **rejected** with a
  logged reason rather than growing the buffer unbounded — backpressure, not OOM.

  This is the **stub**: an in-memory bounded buffer that fixes the policy
  (reject-new on overflow, never silent). The durable implementation is Oban on
  Postgres (system architecture §7) — deferred; the contract here is the policy.

  Performance: O(1) enqueue/dequeue (prepend + reversed drain).
  """

  use GenServer

  require Logger

  @default_max_size 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Enqueue an event. `{:error, :overflow}` (logged) when the buffer is full."
  @spec enqueue(term()) :: :ok | {:error, :overflow}
  def enqueue(event), do: GenServer.call(__MODULE__, {:enqueue, event})

  @doc "Drain up to `n` events in FIFO order."
  @spec drain(pos_integer()) :: [term()]
  def drain(n) when is_integer(n) and n > 0, do: GenServer.call(__MODULE__, {:drain, n})

  @doc "Current buffered count."
  @spec size() :: non_neg_integer()
  def size, do: GenServer.call(__MODULE__, :size)

  @impl GenServer
  def init(opts) do
    {:ok, %{buf: [], count: 0, max_size: Keyword.get(opts, :max_size, @default_max_size)}}
  end

  @impl GenServer
  def handle_call({:enqueue, _event}, _from, %{count: count, max_size: max} = state)
      when count >= max do
    Logger.warning("ingest queue overflow at #{max}; rejecting event (backpressure)")
    {:reply, {:error, :overflow}, state}
  end

  def handle_call({:enqueue, event}, _from, state) do
    {:reply, :ok, %{state | buf: [event | state.buf], count: state.count + 1}}
  end

  def handle_call({:drain, n}, _from, state) do
    ordered = Enum.reverse(state.buf)
    {taken, rest} = Enum.split(ordered, n)
    {:reply, taken, %{state | buf: Enum.reverse(rest), count: state.count - length(taken)}}
  end

  def handle_call(:size, _from, state), do: {:reply, state.count, state}
end
