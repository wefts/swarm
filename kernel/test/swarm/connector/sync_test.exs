defmodule Swarm.Connector.SyncTest do
  @moduledoc """
  T4 — the hostile-source completeness contract (swarm ADR-5) proven end to end.
  The fixture `Swarm.Test.HostileConnector` simulates title-sort + per-page limit
  + flaky fetch + byte ceiling; these tests are the ground-truth gate.
  """
  use Swarm.GraphCase, async: false

  import ExUnit.CaptureLog

  alias Swarm.Connector.Sync
  alias Swarm.Repo
  alias Swarm.Test.HostileConnector

  defmodule EmptyConnector do
    @moduledoc false
    @behaviour Swarm.Ports.Connector
    @impl true
    def describe, do: %{name: "empty"}
  end

  # Returns 2 of a real 10 and lies `cursor: :done` with no `truncated?` — the
  # "trust :done like top-N" hole. Only catchable via coverage reconciliation.
  defmodule LyingConnector do
    @moduledoc false
    @behaviour Swarm.Ports.Connector
    @impl true
    def describe, do: %{name: "liar"}
    @impl true
    def fetch(:start, _opts),
      do: {:ok, %{events: [ev("a"), ev("b")], cursor: :done, truncated?: false}}

    defp ev(k) do
      %{
        provenance: "liar:#{k}",
        occurred_at: ~U[2026-01-01 00:00:00Z],
        entities: [%{type: "file", key: "liar-#{k}", scope: "private", content: k}],
        relations: []
      }
    end
  end

  defp file_count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM node WHERE type = 'file'")
    n
  end

  test "completeness: kernel pagination ingests the COMPLETE set past the list limit" do
    {:ok, r} = Sync.run(HostileConnector, count: 250, page_size: 50)

    assert r.mode == :full
    assert r.complete?
    assert r.ingested == 250
    assert r.pages == 5
    # == the fixture's ground truth; no top-N truncation
    assert file_count() == 250
  end

  test "backpressure: a large source is pulled in bounded pages, not buffered whole" do
    # 600 items at page 50 → 12 bounded pulls; memory is page-bounded, not
    # source-bounded (T10 — the demand-driven backpressure that stops a flood).
    {:ok, r} = Sync.run(HostileConnector, count: 600, page_size: 50)

    assert r.complete?
    assert r.ingested == 600
    assert r.pages == 12
  end

  test "a flaky partial fetch is retried; the run still completes" do
    # Without the retry, page 3 fails and the run is incomplete. Completing at
    # 250 proves the kernel recovered the flaky page.
    {:ok, r} = Sync.run(HostileConnector, count: 250, page_size: 50, flaky_page: 3)

    assert r.complete?
    assert r.ingested == 250
    assert file_count() == 250
  end

  test "a byte ceiling is LOGGED and flagged — never silently dropped" do
    {result, log} =
      with_log(fn -> Sync.run(HostileConnector, count: 250, page_size: 50, ceiling_page: 3) end)

    {:ok, r} = result

    assert r.ceilings == 1
    # the loss is surfaced, not hidden
    refute r.complete?
    assert r.ingested < 250
    assert file_count() == r.ingested
    assert log =~ "ceiling hit"
  end

  test "delta re-ingests only movers (watermark-driven)" do
    {:ok, full} = Sync.run(HostileConnector, count: 50, page_size: 20)
    assert full.ingested == 50

    {:ok, delta} =
      Sync.run(HostileConnector, count: 50, page_size: 20, since: full.watermark, mover_count: 3)

    assert delta.mode == :delta
    # only the 3 movers, not the 50 unchanged
    assert delta.ingested == 3
    assert file_count() == 53
  end

  test "the runner returns a report, never raw source payloads" do
    {:ok, r} = Sync.run(HostileConnector, count: 10, page_size: 5)

    assert Enum.sort(Map.keys(r)) ==
             [:ceilings, :complete?, :duplicates, :errors, :ingested, :mode, :pages, :watermark]

    refute Map.has_key?(r, :events)
  end

  test "a connector implementing neither fetch/2 nor stream/1 is rejected" do
    assert {:error, :connector_implements_neither_fetch_nor_stream} = Sync.run(EmptyConnector)
  end

  test "lying about exhaustion is caught by coverage reconciliation (declared total)" do
    {result, log} = with_log(fn -> Sync.run(LyingConnector, expected_total: 10) end)
    {:ok, r} = result

    # said :done after 2 of 10 → reconciliation flags it, not trusted like top-N
    refute r.complete?
    assert r.ingested == 2
    assert log =~ "coverage shortfall"
  end

  test "without a declared total, an early :done is undetectable (documented ADR-5 limit)" do
    {:ok, r} = Sync.run(LyingConnector)

    # honest: nothing to reconcile against, so the run reads complete
    assert r.complete?
    assert r.ingested == 2
  end
end
