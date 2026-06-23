defmodule Swarm.Connector.Sync do
  @moduledoc """
  Kernel-driven connector sync (swarm ADR-5). The kernel owns completeness: it
  drives a connector's `fetch/2` pagination to exhaustion (or consumes a
  `stream/1` full dump), feeds every event through `Swarm.Ingest`, and returns a
  **report** — never the raw payloads. The graph, not a source dump, is what a
  model later reads.

  Hostile-source guarantees (the glpi-agent lessons):

  - **Completeness in code, not top-N.** The kernel loops on the connector's
    cursor until `:done`; it never trusts a single bounded list.
  - **No silent caps.** A page flagged `truncated?: true` (source ceiling) is
    logged and flips `complete?` to false — the gap is surfaced, never dropped.
  - **Flaky fetches are retried** (`:max_retries`, default 2) before the run is
    declared incomplete — the prototype's resilience.
  - **Demand-driven pull.** One page at a time bounds memory, so a hostile source
    cannot flood the graph (backpressure by construction).
  - **Delta.** With `:since` (a watermark) the run is a delta; the connector
    returns only movers and the report carries the new max `watermark` to persist.
  """

  alias Swarm.Ingest

  require Logger

  @typedoc "Outcome of a sync run; counts + completeness + the watermark to persist."
  @type report :: %{
          mode: :full | :delta,
          ingested: non_neg_integer(),
          duplicates: non_neg_integer(),
          errors: non_neg_integer(),
          pages: non_neg_integer(),
          ceilings: non_neg_integer(),
          complete?: boolean(),
          watermark: DateTime.t() | nil
        }

  # Internal accumulator: the report plus a connector-declared total used for
  # coverage reconciliation, dropped before the report is returned.
  @typep acc :: %{
           mode: :full | :delta,
           ingested: non_neg_integer(),
           duplicates: non_neg_integer(),
           errors: non_neg_integer(),
           pages: non_neg_integer(),
           ceilings: non_neg_integer(),
           complete?: boolean(),
           watermark: DateTime.t() | nil,
           total_hint: non_neg_integer() | nil
         }

  @doc """
  Run a sync for `module`. `opts`: `:since` (a `DateTime` watermark → delta mode),
  `:max_retries` (default 2), plus any connector-specific options passed through
  to `fetch/2` / `stream/1`. Returns `{:ok, report}` or `{:error, reason}` if the
  connector implements neither callback.
  """
  @spec run(module(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(module, opts \\ []) do
    mode = if Keyword.has_key?(opts, :since), do: :delta, else: :full

    acc = %{
      mode: mode,
      ingested: 0,
      duplicates: 0,
      errors: 0,
      pages: 0,
      ceilings: 0,
      complete?: true,
      watermark: Keyword.get(opts, :since),
      # internal: a connector-declared source total, if any (dropped from report)
      total_hint: nil
    }

    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :fetch, 2) ->
        {:ok,
         module
         |> paginate(:start, opts, Keyword.get(opts, :max_retries, 2), acc)
         |> reconcile(module, opts)}

      function_exported?(module, :stream, 1) ->
        {:ok, module.stream(opts) |> Enum.reduce(acc, &ingest_one/2) |> reconcile(module, opts)}

      true ->
        {:error, :connector_implements_neither_fetch_nor_stream}
    end
  end

  # Coverage reconciliation (the early-`:done` / silent-drop guard). If the source
  # can declare a total — via `:expected_total` in opts or a page's `:total` — and
  # fewer items were delivered than that, the run is NOT complete, even though the
  # connector said `:done`. This is the only defense against a connector lying
  # about exhaustion; with no declared total it is undetectable (see ADR-5).
  @spec reconcile(acc(), module(), keyword()) :: report()
  defp reconcile(acc, module, opts) do
    expected = Keyword.get(opts, :expected_total) || acc.total_hint
    delivered = acc.ingested + acc.duplicates

    acc =
      if is_integer(expected) and acc.complete? and delivered < expected do
        Logger.warning(
          "connector #{inspect(module)}: coverage shortfall — delivered #{delivered} of #{expected}; marking incomplete"
        )

        %{acc | complete?: false}
      else
        acc
      end

    Map.delete(acc, :total_hint)
  end

  # The completeness-owning loop: pull a page, ingest it, follow the cursor.
  @spec paginate(module(), term(), keyword(), non_neg_integer(), acc()) :: acc()
  defp paginate(module, cursor, opts, max_retries, acc) do
    case fetch_with_retry(module, cursor, opts, max_retries) do
      {:ok, page} ->
        acc =
          page.events
          |> Enum.reduce(%{acc | pages: acc.pages + 1}, &ingest_one/2)
          |> note_truncation(module, page)
          |> note_total(page)

        case page.cursor do
          :done -> acc
          next -> paginate(module, next, opts, max_retries, acc)
        end

      {:error, reason} ->
        # Retries exhausted on a flaky source: do NOT declare the run complete.
        Logger.warning(
          "connector #{inspect(module)}: fetch failed at cursor #{inspect(cursor)} after retries (#{inspect(reason)}); marking incomplete"
        )

        %{acc | complete?: false, errors: acc.errors + 1}
    end
  end

  @spec fetch_with_retry(module(), term(), keyword(), non_neg_integer()) ::
          {:ok, Swarm.Ports.Connector.page()} | {:error, term()}
  defp fetch_with_retry(module, cursor, opts, tries) do
    case module.fetch(cursor, opts) do
      {:ok, page} ->
        {:ok, page}

      {:error, reason} when tries > 0 ->
        Logger.info(
          "connector #{inspect(module)}: transient fetch error #{inspect(reason)}; retrying (#{tries} left)"
        )

        fetch_with_retry(module, cursor, opts, tries - 1)

      {:error, _reason} = err ->
        err
    end
  end

  # A source ceiling on this page → log it and flip completeness (no silent cap).
  @spec note_truncation(acc(), module(), Swarm.Ports.Connector.page()) :: acc()
  defp note_truncation(acc, module, %{truncated?: true}) do
    Logger.warning(
      "connector #{inspect(module)}: source ceiling hit on page #{acc.pages} — completeness not guaranteed for this page"
    )

    %{acc | ceilings: acc.ceilings + 1, complete?: false}
  end

  defp note_truncation(acc, _module, _page), do: acc

  # A connector that knows the source total may declare it on a page (`:total`);
  # the kernel keeps the max for coverage reconciliation.
  @spec note_total(acc(), map()) :: acc()
  defp note_total(acc, page) do
    case Map.get(page, :total) do
      n when is_integer(n) -> %{acc | total_hint: max(acc.total_hint || 0, n)}
      _ -> acc
    end
  end

  @spec ingest_one(map(), acc()) :: acc()
  defp ingest_one(event, acc) do
    case Ingest.ingest(event) do
      {:ok, :written} -> bump_watermark(%{acc | ingested: acc.ingested + 1}, event)
      {:ok, :duplicate} -> %{acc | duplicates: acc.duplicates + 1}
      {:error, reason} -> log_ingest_error(acc, reason)
    end
  end

  defp log_ingest_error(acc, reason) do
    Logger.warning("connector sync: ingest rejected event (#{inspect(reason)})")
    %{acc | errors: acc.errors + 1}
  end

  @spec bump_watermark(acc(), map()) :: acc()
  defp bump_watermark(acc, event) do
    case occurred_at(event) do
      nil -> acc
      dt -> %{acc | watermark: later(acc.watermark, dt)}
    end
  end

  defp occurred_at(event) do
    case Map.get(event, :occurred_at) do
      %DateTime{} = dt ->
        dt

      s when is_binary(s) ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp later(nil, dt), do: dt
  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
end
