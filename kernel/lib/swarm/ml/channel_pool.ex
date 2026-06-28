defmodule Swarm.ML.ChannelPool do
  @moduledoc """
  A small supervised pool of long-lived gRPC channels to the Python ML pillar.

  This is the kernel's fix for the grpc 0.11.5 `:disconnect` crash: instead of a
  per-call connect → run → disconnect (which crashes `GRPC.Client.Connection` and
  poisons the next connect with `:noproc`), the pool holds a handful of channels
  open for the process lifetime and **never disconnects** them. See
  `Swarm.ML.ChannelPool.Worker` for the full rationale.

  Shape:

  - a `Registry` the workers advertise their channels through;
  - `size` (≈ `replicas × 2`) `Worker`s, each owning one channel and reconnecting
    itself on failure;
  - a `Manager` that hands out a healthy channel round-robin.

  `:rest_for_one` so that if the Registry ever dies, the workers and manager
  restart after it and re-register — never left pointing at a dead registry.

  Config (`config :swarm, :ml_pool`, overridable by env at deploy time):

  - `:enabled` — start the pool with the app (default `true`; tests disable it).
  - `:size` — number of channels (default 4 ≈ the 2 ml replicas × 2); also
    `SWARM_ML_POOL_SIZE`.
  - `:keepalive_ms` — HTTP/2 PING period; REQUIRED to detect half-open conns.
  - `:backoff_ms` / `:backoff_max_ms` — reconnect backoff bounds.
  """
  use Supervisor

  alias Swarm.ML.ChannelPool.{Manager, Worker}

  @registry Swarm.ML.ChannelPool.Registry
  # Each worker owns a unique key `{:ml_channel, index}` whose value is its
  # current channel (or nil while reconnecting); checkout reads them all.
  @worker_tag :ml_channel

  @doc false
  def registry, do: @registry

  @doc false
  def worker_key(index), do: {@worker_tag, index}

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    cfg = Swarm.Config.ml_pool()

    workers =
      for index <- 1..cfg.size do
        Supervisor.child_spec({Worker, {index, cfg}}, id: {Worker, index})
      end

    children = [{Registry, keys: :unique, name: @registry}] ++ workers ++ [Manager]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Pick a healthy channel round-robin, skipping `exclude`. See `Manager.checkout/1`.
  """
  @spec checkout([pid()]) :: {:ok, GRPC.Channel.t(), pid()} | {:error, :unavailable}
  defdelegate checkout(exclude \\ []), to: Manager
end
