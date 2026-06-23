defmodule Swarm.Stigmergy.Dispatch do
  @moduledoc """
  Routes stigmergy outbox rows to the workers that care (swarm ADR-2, steps 4–5).

  Workers subscribe to the `change` kinds they handle. The tailer calls
  `dispatch/1` for each consumed row; the row is routed to the ordered lane for
  its `target_key` (`Swarm.Stigmergy.Lane`), which invokes every interested
  handler. Same-target rows are processed in order on one lane; different targets
  run in parallel. `dispatch/1` returns as soon as the row is queued, so a slow
  handler never stalls the tailer.

  A handler is a `row -> any` function or a module implementing
  `Swarm.Ports.Worker` (its `handle/1` is called). Handlers MUST be idempotent on
  `row.idem_key`: the tailer is at-least-once across restarts.
  """
  use GenServer

  alias Swarm.Coordination.Stagnation
  alias Swarm.Stigmergy.Lane

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Subscribe a handler (fun/1 or `Ports.Worker` module) to one or more change kinds."
  @spec subscribe([String.t()] | String.t(), function() | module(), GenServer.server()) :: :ok
  def subscribe(kinds, handler, server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, List.wrap(kinds), handler})
  end

  @doc "Route a row to its target's lane; interested handlers run there, in order."
  @spec dispatch(map(), GenServer.server()) :: :ok
  def dispatch(row, server \\ __MODULE__), do: GenServer.call(server, {:dispatch, row})

  @impl true
  def init(:ok), do: {:ok, %{subs: %{}, lanes: %{}}}

  @impl true
  def handle_call({:subscribe, kinds, handler}, _from, state) do
    subs =
      Enum.reduce(kinds, state.subs, &Map.update(&2, &1, [handler], fn hs -> [handler | hs] end))

    {:reply, :ok, %{state | subs: subs}}
  end

  def handle_call({:dispatch, row}, _from, state) do
    handlers = Map.get(state.subs, row.change, [])

    # Bystander-effect guard (T13): a row no subscription matches is SURFACED to the
    # stagnation monitor, not silently dropped into a no-op lane.
    if handlers == [], do: Stagnation.record_unmatched(row)

    {lane, lanes} = ensure_lane(state.lanes, row.target_key)
    GenServer.cast(lane, {:invoke, handlers, row})
    {:reply, :ok, %{state | lanes: lanes}}
  end

  # One lane per target_key, kept alive across rows. Handlers are crash-safe, so
  # a lane doesn't die under normal operation; re-create defensively if it did.
  defp ensure_lane(lanes, key) do
    case lanes do
      %{^key => pid} when is_pid(pid) ->
        if Process.alive?(pid), do: {pid, lanes}, else: start_lane(lanes, key)

      _ ->
        start_lane(lanes, key)
    end
  end

  defp start_lane(lanes, key) do
    {:ok, pid} = Lane.start_link([])
    {pid, Map.put(lanes, key, pid)}
  end
end
