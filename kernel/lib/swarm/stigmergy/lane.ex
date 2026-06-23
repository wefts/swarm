defmodule Swarm.Stigmergy.Lane do
  @moduledoc """
  One ordered lane for a single `target_key` (swarm ADR-2, step 5).

  Rows for the same target are processed strictly in arrival order on this one
  process (its mailbox is the queue); lanes for different targets run in parallel.
  So same-target reinforcement stays correctly ordered (ADR-9 workspace) while
  unrelated work scales out. A handler crash is logged and isolated to its row.
  """
  use GenServer

  require Logger

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_cast({:invoke, handlers, row}, state) do
    Enum.each(handlers, &invoke(&1, row))
    {:noreply, state}
  end

  defp invoke(handler, row) when is_function(handler, 1), do: safe(fn -> handler.(row) end)
  defp invoke(module, row) when is_atom(module), do: safe(fn -> module.handle(row) end)

  defp safe(fun) do
    fun.()
  rescue
    e -> Logger.error("stigmergy lane handler crashed: #{inspect(e)}")
  end
end
