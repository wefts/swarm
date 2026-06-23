defmodule Swarm.Coordination.Stagnation do
  @moduledoc """
  Stagnation monitor (T13). Pure stigmergy's named failure is the bystander-effect
  deadlock: a trace nobody handles or claims stalls **forever, silently**. This
  surfaces such traces so a human / fallback escalation can act:

  - **Unhandled change kind** — a dispatched row whose change kind no worker
    subscribes to is recorded once (`record_unmatched/1`, called by
    `Swarm.Stigmergy.Dispatch`). Deduped per `(reason, ref)`, so a high-frequency
    kind surfaces **once**, never one row per write (no flood).
  - **Stalled claim** — `scan_stalls/1` finds claimable `coordination` traces with
    no `claimed_by` older than a TTL and records each (deduped per node). A
    config-gated watchdog runs it on an interval (disabled in tests, which call
    `scan_stalls/1` directly).

  In Swarm's model a below-gate-threshold query is **escalated** (to the
  consilium), not abandoned; the genuinely-abandoned trace is an unclaimed graph
  trace, which the stall scan catches. Inspect with `recent/1` / `count/0`.
  """

  use GenServer

  alias Swarm.Repo

  require Logger

  @default_ttl_s 3_600
  @default_interval_ms 600_000

  # --- pure surfacing (testable) ---------------------------------------------

  @doc "Record a stall once, deduped on `(reason, ref)` — a recurrence is a no-op."
  @spec record(String.t(), String.t(), String.t() | nil) :: :ok
  def record(reason, ref, detail \\ nil) do
    Repo.query!(
      "INSERT INTO stagnant (reason, ref, detail) VALUES ($1, $2, $3) " <>
        "ON CONFLICT (reason, ref) DO NOTHING",
      [reason, ref, detail]
    )

    :ok
  end

  @doc "Surface a dispatched row that matched no subscription (deduped per change kind)."
  @spec record_unmatched(map()) :: :ok
  def record_unmatched(row) do
    change = Map.get(row, :change)
    record("no_subscriber", to_string(change), "target=#{Map.get(row, :target_key)}")
    Logger.warning("stagnation: change '#{change}' has no subscriber — surfaced (deduped)")
    :ok
  end

  @doc """
  Scan for claimable `coordination` traces unclaimed past `ttl_seconds` and record
  each as a stalled claim (deduped per node). Returns how many stalls are open.
  """
  @spec scan_stalls(non_neg_integer()) :: non_neg_integer()
  def scan_stalls(ttl_seconds \\ @default_ttl_s) do
    stalled = unclaimed(ttl_seconds)
    Enum.each(stalled, &record("stalled_claim", to_string(&1), "unclaimed coordination trace"))
    length(stalled)
  end

  @doc "Claimable `coordination` node ids with no `claimed_by` older than `ttl_seconds`."
  @spec unclaimed(non_neg_integer()) :: [integer()]
  def unclaimed(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    sql = """
    SELECT id FROM node
     WHERE kind = 'coordination'
       AND claimed_by IS NULL
       AND created_at < now() - ($1::int * interval '1 second')
    """

    %{rows: rows} = Repo.query!(sql, [ttl_seconds])
    Enum.map(rows, fn [id] -> id end)
  end

  @doc "Open stall count."
  @spec count() :: non_neg_integer()
  def count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM stagnant")
    n
  end

  @doc "The most recent surfaced stalls (reason + ref + detail)."
  @spec recent(pos_integer()) :: [
          %{reason: String.t(), ref: String.t(), detail: String.t() | nil}
        ]
  def recent(n \\ 20) when is_integer(n) and n > 0 do
    %{rows: rows} =
      Repo.query!("SELECT reason, ref, detail FROM stagnant ORDER BY id DESC LIMIT $1", [n])

    Enum.map(rows, fn [r, ref, d] -> %{reason: r, ref: ref, detail: d} end)
  end

  # --- the periodic watchdog -------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval_ms, @default_interval_ms),
      ttl_s: Keyword.get(opts, :ttl_s, @default_ttl_s)
    }

    schedule(state.interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    open = scan_stalls(state.ttl_s)
    if open > 0, do: Logger.warning("stagnation: #{open} unclaimed coordination trace(s) open")
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :scan, interval)
end
