defmodule Swarm.Graph.ContentChunkTest do
  @moduledoc """
  The stateless content/chunk side-store invariants (swarm ADR-14 §1). These are
  structural guarantees of the DDL, not behaviour: no `scope` column on either
  tier (scope lives only on `node`), FK CASCADE so a deleted node reaps its body
  and spans, the HNSW + FTS retrieval indexes exist, and a node carries at most
  one content row with uniquely-ordered chunks.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Repo

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp index_names(table) do
    %{rows: rows} = Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = $1", [table])
    rows |> List.flatten() |> MapSet.new()
  end

  defp node!(key) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO node (type, key, scope) VALUES ('article', $1, 'public') RETURNING id",
        [key]
      )

    id
  end

  test "neither content nor chunk carries a scope column (single source of truth on node)" do
    refute MapSet.member?(columns("content"), "scope")
    refute MapSet.member?(columns("chunk"), "scope")
    # scope is reachable only through the node
    assert MapSet.member?(columns("node"), "scope")
  end

  test "deleting a node CASCADE-reaps its content and chunks (no orphan handle)" do
    nid = node!("Cascade Source")

    Repo.query!(
      "INSERT INTO content (node_id, body, body_hash, segmenter) VALUES ($1, 'b', 'h', 'prose')",
      [nid]
    )

    Repo.query!(
      "INSERT INTO chunk (node_id, ordinal, text, embed_model, token_count) VALUES ($1, 0, 's0', 'bge-m3', 1), ($1, 1, 's1', 'bge-m3', 1)",
      [nid]
    )

    assert Repo.query!("SELECT count(*) FROM chunk WHERE node_id = $1", [nid]).rows == [[2]]

    Repo.query!("DELETE FROM node WHERE id = $1", [nid])

    assert Repo.query!("SELECT count(*) FROM content WHERE node_id = $1", [nid]).rows == [[0]]
    assert Repo.query!("SELECT count(*) FROM chunk WHERE node_id = $1", [nid]).rows == [[0]]
  end

  test "the HNSW (dense) and FTS (lexical) retrieval indexes both exist on chunk" do
    idx = index_names("chunk")
    assert MapSet.member?(idx, "chunk_vec_hnsw")
    assert MapSet.member?(idx, "chunk_text_fts")
  end

  test "content is 1:1 with its node (node_id PK) and chunk ordinals are unique per node" do
    nid = node!("Unique Source")

    Repo.query!(
      "INSERT INTO content (node_id, body, body_hash, segmenter) VALUES ($1, 'b', 'h', 'prose')",
      [nid]
    )

    # second body for the same node violates the content PK
    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "INSERT INTO content (node_id, body, body_hash, segmenter) VALUES ($1, 'b2', 'h2', 'prose')",
        [nid]
      )
    end

    Repo.query!("INSERT INTO chunk (node_id, ordinal, text) VALUES ($1, 0, 's')", [nid])

    # duplicate ordinal for the same node violates the chunk natural key
    assert_raise Postgrex.Error, fn ->
      Repo.query!("INSERT INTO chunk (node_id, ordinal, text) VALUES ($1, 0, 's-dup')", [nid])
    end
  end
end
