defmodule Swarm.Graph.ChunkScopeMirrorTest do
  @moduledoc """
  ADR-0016 bm25 arm: `chunk` carries a trigger-maintained MIRROR of `node.scope`
  and `node.key` (as `title`), so the pg_search bm25 index can filter scope +
  field-boost the title IN-index (filter-before-rank — the no-leak property).
  `node.scope` stays authoritative (the retrieval query still joins it as the belt);
  these tests prove the mirror never drifts under insert or node mutation.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp chunk_mirror(node_id) do
    %{rows: [[scope, title]]} =
      Repo.query!("SELECT scope, title FROM chunk WHERE node_id = $1 LIMIT 1", [node_id])

    {scope, title}
  end

  defp insert_chunk!(node_id),
    do:
      Repo.query!("INSERT INTO chunk (node_id, ordinal, text) VALUES ($1, 0, 'body')", [node_id])

  test "a new chunk mirrors its node's scope and key on insert" do
    nid = Store.upsert_node("article", "Public IP", scope: "group")
    insert_chunk!(nid)

    assert {"group", "Public IP"} == chunk_mirror(nid)
  end

  test "changing node.scope propagates to its chunks (no stale-permissive mirror)" do
    nid = Store.upsert_node("article", "Secret", scope: "group")
    insert_chunk!(nid)
    assert {"group", "Secret"} == chunk_mirror(nid)

    Repo.query!("UPDATE node SET scope = 'private' WHERE id = $1", [nid])

    assert {"private", "Secret"} == chunk_mirror(nid)
  end

  test "changing node.key propagates to its chunks' title" do
    nid = Store.upsert_node("article", "Old Title", scope: "public")
    insert_chunk!(nid)

    Repo.query!("UPDATE node SET key = 'New Title' WHERE id = $1", [nid])

    assert {"public", "New Title"} == chunk_mirror(nid)
  end
end
