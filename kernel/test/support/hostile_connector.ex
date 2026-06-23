defmodule Swarm.Test.HostileConnector do
  @moduledoc """
  A reference connector built against a HOSTILE source (T4), to prove the swarm
  ADR-5 ingestion contract end to end. It simulates the real-world pathologies
  the glpi-agent fought:

  - **title-sorted + hard per-page limit** — a page returns at most `:page_size`
    items, sorted by title; there is no server-side date filter;
  - **keyset (cursor) pagination** — the cursor is the last title seen, so the
    kernel can paginate to exhaustion past any naive offset/byte ceiling;
  - **flaky partial fetch** — `:flaky_page` fails its FIRST attempt (then
    succeeds), exercising the runner's retry;
  - **byte ceiling** — `:ceiling_page` genuinely clips half its window (those
    items are LOST) and flags `truncated?: true`, so the loss is surfaced
    (logged + `complete? == false`), never silently dropped.

  Config via `opts`: `:count` (ground-truth size), `:page_size`, `:flaky_page`,
  `:ceiling_page`, `:mover_count` (extra movers visible only in a delta run).
  """

  @behaviour Swarm.Ports.Connector

  @base ~U[2026-01-01 00:00:00Z]

  @impl true
  def describe, do: %{name: "hostile_fixture", kind: :connector, sync_modes: [:full, :delta]}

  @impl true
  def fetch(:start, opts) do
    reset_attempts()
    fetch(0, opts)
  end

  def fetch(cursor, opts) when is_binary(cursor) do
    all = sorted(opts)
    start_idx = (Enum.find_index(all, &(&1.title == cursor)) || -1) + 1
    page(all, start_idx, opts)
  end

  def fetch(start_idx, opts) when is_integer(start_idx) do
    page(sorted(opts), start_idx, opts)
  end

  # --- the hostile page primitive -------------------------------------------

  defp page(all, start_idx, opts) do
    page_size = opts[:page_size] || 50
    page_num = div(start_idx, page_size) + 1
    window = all |> Enum.drop(start_idx) |> Enum.take(page_size)

    cond do
      page_num == opts[:flaky_page] && first_attempt?(start_idx) ->
        {:error, :flaky_partial_fetch}

      page_num == opts[:ceiling_page] ->
        # byte ceiling: only half the window survives; the rest is LOST, and the
        # cursor advances past the full window so they are never re-fetched.
        kept = Enum.take(window, max(div(page_size, 2), 1))

        {:ok,
         %{
           events: Enum.map(kept, &to_event/1),
           cursor: next_cursor(all, start_idx, page_size, window),
           truncated?: true
         }}

      true ->
        {:ok,
         %{
           events: Enum.map(window, &to_event/1),
           cursor: next_cursor(all, start_idx, page_size, window),
           truncated?: false
         }}
    end
  end

  defp next_cursor(all, start_idx, page_size, window) do
    if start_idx + page_size >= length(all) or window == [] do
      :done
    else
      List.last(window).title
    end
  end

  # --- the hostile dataset ---------------------------------------------------

  defp sorted(opts), do: opts |> dataset() |> Enum.sort_by(& &1.title)

  defp dataset(opts) do
    count = opts[:count] || 250
    core = for i <- 1..count, do: item(i, DateTime.add(@base, i, :second))

    movers =
      if opts[:since] do
        for i <- (count + 1)..(count + (opts[:mover_count] || 0))//1,
            do: item(i, DateTime.add(@base, count + i, :second))
      else
        []
      end

    filter_since(core ++ movers, opts[:since])
  end

  defp filter_since(items, nil), do: items

  defp filter_since(items, %DateTime{} = since),
    do: Enum.filter(items, &(DateTime.compare(&1.occurred_at, since) == :gt))

  defp item(i, occurred_at) do
    %{
      id: i,
      title: "doc-" <> String.pad_leading(Integer.to_string(i), 4, "0"),
      occurred_at: occurred_at
    }
  end

  defp to_event(item) do
    %{
      # provenance = evidential origin (doc identity), not emission instance.
      provenance: "hostile:#{item.title}",
      occurred_at: item.occurred_at,
      entities: [%{type: "file", key: item.title, scope: "private", content: item.title}],
      relations: []
    }
  end

  # --- flaky-once bookkeeping (reset per run at :start) -----------------------

  defp first_attempt?(cursor) do
    key = {__MODULE__, :attempt, cursor}

    case Process.get(key) do
      nil -> Process.put(key, 1) && true
      _ -> false
    end
  end

  defp reset_attempts do
    for {__MODULE__, :attempt, _} = k <- Process.get_keys(), do: Process.delete(k)
    :ok
  end
end
