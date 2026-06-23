defmodule Swarm.Graph.GC do
  @moduledoc """
  Trace garbage collection (T11, ADR-9). Stigmergic traces must **evaporate** if
  not reinforced — else the blackboard becomes append-only and the O(1) graph
  degrades to O(N) scans (the operational half of N1). This reaps edges whose
  **decayed strength has fallen below a floor** — i.e. traces the decay
  (`Swarm.Graph.Strength`) has effectively forgotten.

  `reap/1` is the pure operation (one indexed-friendly `DELETE`, testable). A
  thin config-gated GenServer runs it on an interval (disabled in tests, which
  call `reap/1` directly).

  ## The decay knob ρ (re-derive per scale)

  ρ is `Config.decay_lambda` (the `exp(-ρ·age_days)` rate). It is the **master
  stability knob**: ρ=0 never forgets (saturation), too high erases live signal.
  Like the gate bands, it is **nomic-scale-specific** — re-derive it per corpus,
  do not port a constant. Procedure: pick a target half-life H (after H days, an
  un-reinforced trace should be GC-eligible) and set `ρ = ln(2)/H`; then choose
  the reap `:floor` as the strength below which a trace is noise for your corpus
  (measure the strength distribution of known-stale vs live edges; the floor is
  the separating value). Bounded ABOVE by the Hill saturation (`< 1`, ADR-9);
  unlike MMAS there is **no min floor** — Swarm wants full evaporation so GC can
  reap, not a permanent exploration pheromone.
  """

  use GenServer

  alias Swarm.Config
  alias Swarm.Repo

  require Logger

  @default_floor 0.05
  @default_interval_ms 3_600_000

  # --- pure operations (the testable core) -----------------------------------

  @doc """
  Reap edges whose decayed strength is below `:floor` (default #{@default_floor}):
  `saturation(seen_count) · exp(-ρ·age_days) < floor`. Returns the count reaped.
  One set-based `DELETE`; ρ and S come from the tuning inventory (Config).
  """
  @spec reap(keyword()) :: non_neg_integer()
  def reap(opts \\ []) do
    floor = Keyword.get(opts, :floor, @default_floor)
    lambda = Config.decay_lambda()
    s = Config.saturation_s()

    # Reap a trace if EITHER it has evaporated (decayed strength below the floor)
    # OR it was refuted (external reward < 0, T12) — a refuted trace must not linger
    # as ground for the next worker, regardless of how fresh/reinforced it is.
    sql = """
    DELETE FROM edge
     WHERE reward < 0
        OR (ln(1 + seen_count) / (ln(1 + seen_count) + $2::float8))
           * exp(-$1::float8 * EXTRACT(EPOCH FROM (now() - last_seen)) / 86400.0)
         < $3::float8
    """

    %{num_rows: n} = Repo.query!(sql, [lambda, s, floor])
    n
  end

  @doc "Working-set size — the saturation metric (edges + nodes). Cheap counts."
  @spec saturation() :: %{edges: non_neg_integer(), nodes: non_neg_integer()}
  def saturation do
    %{rows: [[edges]]} = Repo.query!("SELECT count(*) FROM edge")
    %{rows: [[nodes]]} = Repo.query!("SELECT count(*) FROM node")
    %{edges: edges, nodes: nodes}
  end

  # --- the periodic job ------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    floor = Keyword.get(opts, :floor, @default_floor)
    schedule(interval)
    {:ok, %{interval: interval, floor: floor}}
  end

  @impl GenServer
  def handle_info(:reap, state) do
    reaped = reap(floor: state.floor)
    sat = saturation()
    Logger.info("graph GC: reaped #{reaped} evaporated edge(s); working set #{sat.edges} edges")
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :reap, interval)
end
