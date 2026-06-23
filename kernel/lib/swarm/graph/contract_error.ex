defmodule Swarm.Graph.ContractError do
  @moduledoc """
  Raised by a raw-SQL write path (`Store.upsert_node`) when the graph contract
  (ADR-4) is violated. A *specific* exception so the ingest poison-path rescue
  (T10) catches a contract violation precisely — and a genuine bug (a plain
  `ArgumentError`) still crashes loud rather than being mislabeled a poison trace.
  """
  defexception [:message, :reason]

  @impl true
  def exception(reason) do
    %__MODULE__{reason: reason, message: "graph contract: #{inspect(reason)}"}
  end
end
