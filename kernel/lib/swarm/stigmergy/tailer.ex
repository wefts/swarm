defmodule Swarm.Stigmergy.Tailer do
  @moduledoc """
  The stigmergy tailer (swarm ADR-2 / docs/design/stigmergy-signal.md).

  A supervised singleton that consumes `outbox` rows in `seq` order past a
  persisted cursor and hands each to a `handler`. The cursor is the source of
  truth; a restart resumes from it (at-least-once — handlers must be idempotent
  on `idem_key`). Postgres `LISTEN/NOTIFY` is a low-latency wake **hint**; a poll
  is the fallback that guarantees progress even if a notification is dropped.

  Step 2 of the signal: ordered consumption + durable cursor. Gap detection
  (step 3), worker dispatch (step 4) and per-key lanes (step 5) build on this.
  """
  use GenServer

  require Logger

  alias Swarm.Repo

  @channel "stigmergy"
  @default_poll_ms 1_000
  @default_gap_ms 2_000

  @type row :: %{
          seq: integer(),
          change: String.t(),
          target_key: String.t(),
          payload: map(),
          idem_key: String.t()
        }

  @doc """
  Start the tailer. Opts: `:name`, `:handler` (a `row -> any` fun), `:poll_ms`.
  The default handler logs at debug — real dispatch arrives in step 4.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force a synchronous drain (deterministic for tests / post-write nudge)."
  @spec drain(GenServer.server()) :: :ok
  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain)

  @impl true
  def init(opts) do
    state = %{
      cursor: load_cursor(),
      handler: Keyword.get(opts, :handler, &default_handler/1),
      poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
      gap_ms: Keyword.get(opts, :gap_ms, @default_gap_ms),
      gap: nil
    }

    listen()
    schedule_poll(state)
    {:ok, run(state)}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    state = run(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    schedule_poll(state)
    {:noreply, run(state)}
  end

  def handle_info({:notification, _pid, _ref, @channel, _payload}, state),
    do: {:noreply, run(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ------------------------------------------------------------

  # Consume rows in `seq` order from `cursor + 1`, stopping at the first unfilled
  # gap. A gap is in-flight (wait and re-read) until it is older than `gap_ms`,
  # then it is treated as rolled-back and skipped — so nothing is silently dropped
  # and nothing is processed out of order (swarm ADR-2 / ADR-9 workspace).
  defp run(state), do: process(fetch_after(state.cursor), state)

  defp process([], state), do: %{state | gap: nil}

  defp process([row | rest], state) do
    expected = state.cursor + 1

    cond do
      row.seq == expected ->
        process(rest, consume(row, state))

      gap_expired?(state, expected) ->
        Logger.warning("stigmergy: skipping rolled-back gap at seq #{expected}..#{row.seq - 1}")
        process(rest, consume(row, state))

      true ->
        # Gap not yet old enough — wait; leave `row` unconsumed for a later pass.
        %{state | gap: note_gap(state.gap, expected)}
    end
  end

  defp consume(row, state) do
    state.handler.(row)
    advance_cursor(row.seq)
    %{state | cursor: row.seq, gap: nil}
  end

  defp note_gap({seq, _t0} = gap, seq), do: gap
  defp note_gap(_other, seq), do: {seq, System.monotonic_time(:millisecond)}

  defp gap_expired?(%{gap: {seq, t0}, gap_ms: gap_ms}, seq),
    do: System.monotonic_time(:millisecond) - t0 >= gap_ms

  defp gap_expired?(_state, _expected), do: false

  defp fetch_after(cursor) do
    %{rows: rows} =
      Repo.query!(
        "SELECT seq, change, target_key, payload, idem_key FROM outbox WHERE seq > $1 ORDER BY seq",
        [cursor]
      )

    Enum.map(rows, fn [seq, change, tkey, payload, idem] ->
      %{seq: seq, change: change, target_key: tkey, payload: decode(payload), idem_key: idem}
    end)
  end

  # The custom Postgrex types module (pgvector) doesn't decode jsonb on raw
  # queries, so it comes back as text; decode it to a map. Tolerate either.
  defp decode(p) when is_binary(p), do: Jason.decode!(p)
  defp decode(p) when is_map(p), do: p

  defp load_cursor do
    %{rows: [[pos]]} = Repo.query!("SELECT position FROM outbox_cursor WHERE id = 1")
    pos
  end

  defp advance_cursor(seq) do
    Repo.query!("UPDATE outbox_cursor SET position = $1 WHERE id = 1", [seq])
  end

  defp schedule_poll(state), do: Process.send_after(self(), :poll, state.poll_ms)

  # Best-effort wake hint. Correctness comes from the poll + cursor, so a failed
  # listener is logged, not fatal.
  defp listen do
    with {:ok, pid} <- Postgrex.Notifications.start_link(Repo.config()),
         {:ok, _ref} <- Postgrex.Notifications.listen(pid, @channel) do
      :ok
    else
      other -> Logger.debug("stigmergy listener unavailable (poll fallback): #{inspect(other)}")
    end
  end

  defp default_handler(row), do: Logger.debug("stigmergy: #{row.change} #{row.target_key}")
end
