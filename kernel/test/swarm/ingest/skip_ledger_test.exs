defmodule Swarm.Ingest.SkipLedgerTest do
  use Swarm.GraphCase, async: false

  import ExUnit.CaptureLog

  alias Swarm.Ingest.SkipLedger

  defp skip(source_ref, reason \\ "template") do
    %{
      connector: "Hive.Proxmox.Connector",
      source: "proxmox",
      source_ref: source_ref,
      reason: reason,
      occurred_at: ~U[2026-09-03 12:00:00Z]
    }
  end

  test "accepts flat and site-qualified source refs; replays update the row" do
    assert :ok = SkipLedger.record(skip("confluence:101"))
    assert :ok = SkipLedger.record(skip("proxmox:casa:vm:101"))
    assert :ok = SkipLedger.record(skip("proxmox:casa:vm:101"))
    assert SkipLedger.count() == 2
  end

  test "rejects a malformed ref or reason loudly, never silently" do
    log =
      capture_log(fn ->
        assert {:error, {:malformed, :source_ref}} = SkipLedger.record(skip("proxmox:"))
        assert {:error, {:malformed, :source_ref}} = SkipLedger.record(skip("Proxmox:vm:1"))

        assert {:error, {:malformed, :reason}} =
                 SkipLedger.record(skip("proxmox:vm:1", "Bad Reason"))
      end)

    assert log =~ "rejected skip row"
    assert SkipLedger.count() == 0
  end
end
