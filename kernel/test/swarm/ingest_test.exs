defmodule Swarm.IngestTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Ingest

  defp event(provenance, opts \\ []) do
    file_key = Keyword.get(opts, :file_key, "/a/f.txt")

    %{
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
