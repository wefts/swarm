defmodule Swarm.Plugins.Registry do
  @moduledoc """
  Live registry of loaded connector adapters (Domain 3 worker/connector
  registry). Loads from `Swarm.Plugins` at startup; `reload/0` re-scans.
  """

  use GenServer

  alias Swarm.Plugins

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "All loaded connectors."
  @spec connectors() :: [Plugins.connector()]
  def connectors, do: GenServer.call(__MODULE__, :connectors)

  @doc "Look up a connector by its declared name."
  @spec lookup(String.t()) :: {:ok, Plugins.connector()} | :error
  def lookup(name), do: GenServer.call(__MODULE__, {:lookup, name})

  @doc "Re-scan the plugins dir."
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl GenServer
  def init(opts) do
    dir = Keyword.get(opts, :dir, Plugins.dir())
    {:ok, %{dir: dir, connectors: load(dir)}}
  end

  @impl GenServer
  def handle_call(:connectors, _from, state), do: {:reply, Map.values(state.connectors), state}

  def handle_call({:lookup, name}, _from, state),
    do: {:reply, Map.fetch(state.connectors, name), state}

  def handle_call(:reload, _from, state),
    do: {:reply, :ok, %{state | connectors: load(state.dir)}}

  @spec load(String.t()) :: %{optional(String.t()) => Plugins.connector()}
  defp load(dir), do: Map.new(Plugins.load_connectors(dir), &{&1.name, &1})
end
