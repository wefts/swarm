defmodule Swarm.Gate.Telemetry do
  @moduledoc """
  Cost telemetry for the gate (Domain 5): per-tier counters and the headline
  "% handled without escalation". O(1) `:ets` counter updates.
  """

  use GenServer

  @table __MODULE__
  @tiers [:tier0, :tier_tools, :escalate]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Increment the counter for a routed tier."
  @spec count(:tier0 | :tier_tools | :escalate) :: :ok
  def count(tier) when tier in @tiers do
    :ets.update_counter(@table, tier, {2, 1}, {tier, 0})
    :ok
  end

  @doc "Current counts per tier."
  @spec snapshot() :: %{
          tier0: non_neg_integer(),
          tier_tools: non_neg_integer(),
          escalate: non_neg_integer()
        }
  def snapshot do
    Map.new(@tiers, fn tier ->
      {tier, :ets.lookup_element(@table, tier, 2, 0)}
    end)
  end

  @doc "Fraction handled by a cheap tier (not escalated). 1.0 when nothing routed yet."
  @spec pct_handled() :: float()
  def pct_handled do
    s = snapshot()
    total = s.tier0 + s.tier_tools + s.escalate
    if total == 0, do: 1.0, else: (s.tier0 + s.tier_tools) / total
  end

  @doc "Reset all counters (test support)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, write_concurrency: true])
    {:ok, %{}}
  end
end
