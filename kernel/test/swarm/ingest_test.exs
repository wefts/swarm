defmodule Swarm.IngestTest do
  use Swarm.GraphCase, async: false

  import ExUnit.CaptureLog

  alias Swarm.Ingest

  defp event(provenance, opts \\ []) do
    file_key = Keyword.get(opts, :file_key, "/a/f.txt")

    base = %{
      source: "test",
      provenance: provenance,
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now()),
      entities: [
        %{
          type: "file",
          key: file_key,
          scope: Keyword.get(opts, :file_scope, "private"),
          content: "f"
        },
        %{type: "dir", key: "/a", scope: Keyword.get(opts, :dir_scope, "private"), content: "a"}
      ],
      relations: [%{from: file_key, to: "/a", type: "contained_in"}]
    }

    case Keyword.get(opts, :origin) do
      nil -> base
      origin -> Map.put(base, :origin, origin)
    end
  end

  defp edge_seen_count do
    %{rows: [[n]]} = Repo.query!("SELECT seen_count FROM edge LIMIT 1")
    n
  end

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}")
    n
  end

  test "writes nodes and a typed edge" do
    assert {:ok, :written} = Ingest.ingest(event("p1"))
    assert count("node") == 2
    assert count("edge") == 1
  end

  test "persists each content-bearing entity's body and signals it for embedding (ADR-14 §2)" do
    assert {:ok, :written} = Ingest.ingest(event("pc"))

    # both entities carry a body ("f", "a") → a content row each, no chunks yet
    # (embedding is the separate worker step), and a content_added signal each.
    assert count("content") == 2
    assert count("chunk") == 0
    assert Repo.query!("SELECT body FROM content ORDER BY body").rows == [["a"], ["f"]]

    assert Repo.query!("SELECT count(*) FROM outbox WHERE change = 'content_added'").rows == [[2]]
  end

  test "same origin, distinct events do NOT over-corroborate; a distinct origin does (ADR-13)" do
    # Two distinct emission events (different provenance) from ONE source origin:
    # the edge is reinforced once — N derivatives of one source are not N witnesses.
    assert {:ok, :written} = Ingest.ingest(event("ev-1", origin: "doc-A"))
    assert {:ok, :written} = Ingest.ingest(event("ev-2", origin: "doc-A"))
    assert edge_seen_count() == 1

    # A genuinely independent origin asserting the same relation does corroborate.
    assert {:ok, :written} = Ingest.ingest(event("ev-3", origin: "doc-B"))
    assert edge_seen_count() == 2
  end

  test "absent origin defaults to provenance and is logged, not silent (back-compat)" do
    log =
      capture_log(fn ->
        assert {:ok, :written} = Ingest.ingest(event("ev-1"))
      end)

    # The degradation is observable (ADR-13 / no-silent-failures), tagged by source.
    assert log =~ "no evidential origin"
    assert log =~ ~s(source="test")

    assert {:ok, :written} = Ingest.ingest(event("ev-2"))
    # Distinct events with no origin each become their own origin → still reinforce.
    assert edge_seen_count() == 2
  end

  test "a duplicate event (same provenance) does not double-write" do
    assert {:ok, :written} = Ingest.ingest(event("p1"))
    assert {:ok, :duplicate} = Ingest.ingest(event("p1"))
    assert count("node") == 2
    assert count("edge") == 1
  end

  test "naive timestamp is rejected (never stamped as UTC) — quarantined (T10)" do
    assert {:error, {:quarantined, {:bad_timestamp, _}}} =
             Ingest.ingest(event("p1", occurred_at: ~N[2026-01-01 00:00:00]))
  end

  test "ISO-8601 with an offset is accepted" do
    assert {:ok, :written} = Ingest.ingest(event("p2", occurred_at: "2026-01-01T12:00:00+02:00"))
  end

  test "Unicode is stored NFC (no lossy fold)" do
    # "e" + U+0301 combining acute (decomposed)
    decomposed = "cafe\u0301"
    composed = :unicode.characters_to_nfc_binary(decomposed)
    assert composed != decomposed

    assert {:ok, :written} = Ingest.ingest(event("p3", file_key: decomposed))

    %{rows: rows} =
      Repo.query!("SELECT key FROM node WHERE type = 'file' AND key = $1", [composed])

    assert rows == [[composed]]
  end

  test "an edge inherits the narrowest endpoint scope (ADR-5)" do
    assert {:ok, :written} =
             Ingest.ingest(event("p4", file_scope: "public", dir_scope: "private"))

    %{rows: [[scope]]} = Repo.query!("SELECT visibility_scope FROM edge LIMIT 1")
    assert scope == "private"
  end
end
