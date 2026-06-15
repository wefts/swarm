defmodule Swarm.Ingest.Dedup do
  @moduledoc """
  Cheap content-key dedup pre-filter (the Bloom-filter stand-in of Domain 2).
  In-memory ETS set of seen provenance keys — a fast first pass so a repeated
  event skips the graph write entirely.

  This is an optimization, not the source of truth: the DB upsert (node identity
  key + edge provenance guard) is the *authoritative*, restart-durable dedup.
  This set is rebuilt lazily as events flow after a restart.

  Performance: O(1) `:ets` membership/insert.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True if this provenance key has been seen since startup."
  @spec seen?(String.t()) :: boolean()
  def seen?(provenance), do: :ets.member(@table, provenance)

  @doc "Record a provenance key as seen."
  @spec mark(String.t()) :: :ok
  def mark(provenance) do
    :ets.insert(@table, {provenance})
    :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
