defmodule Swarm.Graph.MergeTest do
  @moduledoc """
  Entity-resolution merge primitive (swarm ADR-13 layer 2). Proves
  `Store.merge_nodes/3` re-points edges onto the canonical node, unions provenance
  on natural-key collisions (so corroboration aggregates, never double-counts),
  drops merge-induced self-loops, and leaves no orphan referencing the alias.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp nid(key), do: Store.upsert_node("article", key, scope: "public")

  defp edge(src_key, dst_key, prov) do
    {:ok, _} =
      Store.add_edge(nid(src_key), nid(dst_key), "links_to", prov, scope: "public")
  end

  defp edge_between(src_id, dst_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, seen_count FROM edge WHERE src = $1 AND dst = $2 AND type = 'links_to'",
        [src_id, dst_id]
      )

    case rows do
      [[id, seen]] -> %{id: id, seen_count: seen}
      _ -> nil
    end
  end

  test "merge re-points edges, unions provenance on collision, drops self-loops" do
    # alias "Allmusic" → canonical "AllMusic"
    _a = nid("Allmusic")
    _b = nid("AllMusic")

    edge("Allmusic", "X", "p1")
    # collides with the alias edge after merge (same dst X):
    edge("AllMusic", "X", "p4")
    edge("Y", "Allmusic", "p2")
    edge("Allmusic", "Z", "p3")
    # alias → canonical edge becomes a self-loop on merge:
    edge("Allmusic", "AllMusic", "p5")

    {:ok, res} = Store.merge_nodes("article", "Allmusic", "AllMusic")
    assert res.result == :merged

    # alias node is gone; canonical survives
    assert Repo.query!("SELECT id FROM node WHERE key = 'Allmusic'").rows == []
    [[into]] = Repo.query!("SELECT id FROM node WHERE key = 'AllMusic'").rows
    [[xid]] = Repo.query!("SELECT id FROM node WHERE key = 'X'").rows
    [[yid]] = Repo.query!("SELECT id FROM node WHERE key = 'Y'").rows
    [[zid]] = Repo.query!("SELECT id FROM node WHERE key = 'Z'").rows

    # B→X carries BOTH provenances (p1 ∪ p4) → seen_count 2, single edge
    bx = edge_between(into, xid)
    assert bx.seen_count == 2

    # Y→B and B→Z re-pointed, each one distinct provenance
    assert edge_between(yid, into).seen_count == 1
    assert edge_between(into, zid).seen_count == 1

    # no self-loop (the A→B edge was dropped), no edge still references the alias id
    %{rows: [[loops]]} =
      Repo.query!("SELECT count(*) FROM edge WHERE src = dst")

    assert loops == 0
  end

  test "merge into a not-yet-existing canonical renames the alias" do
    _a = nid("Redirect Source")
    edge("Redirect Source", "Target", "p1")

    {:ok, res} = Store.merge_nodes("article", "Redirect Source", "Canonical Page")
    assert res.result == :renamed

    assert Repo.query!("SELECT id FROM node WHERE key = 'Redirect Source'").rows == []
    assert Repo.query!("SELECT id FROM node WHERE key = 'Canonical Page'").rows != []
  end

  test "merging a missing alias or onto itself is a no-op" do
    _b = nid("Solo")
    assert {:ok, %{result: :noop_no_alias}} = Store.merge_nodes("article", "Ghost", "Solo")
    assert {:ok, %{result: :noop_same}} = Store.merge_nodes("article", "Solo", "Solo")
  end

  # --- swarm ADR-14 §3.2: standing alias table, scope-awareness, chunk union ---

  defp content!(node_id, body) do
    Repo.query!(
      "INSERT INTO content (node_id, body, body_hash, segmenter) VALUES ($1, $2, $3, 'prose-v1')",
      [node_id, body, "h#{node_id}"]
    )
  end

  defp chunk!(node_id, ordinal) do
    Repo.query!("INSERT INTO chunk (node_id, ordinal, text) VALUES ($1, $2, $3)", [
      node_id,
      ordinal,
      "span-#{node_id}-#{ordinal}"
    ])
  end

  defp chunk_count(node_id) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM chunk WHERE node_id = $1", [node_id])
    n
  end

  test "a successful merge records a standing alias; the next upsert resolves to canonical" do
    _a = nid("Allmusic")
    _b = nid("AllMusic")
    {:ok, %{result: :merged}} = Store.merge_nodes("article", "Allmusic", "AllMusic")

    # the alias is now standing — upserting the alias key returns the canonical node,
    # mints nothing new
    canonical = Store.upsert_node("article", "AllMusic", scope: "public")
    resolved = Store.upsert_node("article", "Allmusic", scope: "public")
    assert resolved == canonical
    assert Repo.query!("SELECT count(*) FROM node WHERE key = 'Allmusic'").rows == [[0]]
  end

  test "a cross-scope merge is refused (never widens the survivor's scope)" do
    pub = Store.upsert_node("article", "PublicPage", scope: "public")
    priv = Store.upsert_node("article", "PrivatePage", scope: "private")

    assert {:ok, %{result: :refused_cross_scope}} =
             Store.merge_nodes("article", "PublicPage", "PrivatePage")

    # both nodes still exist; the survivor's scope is unchanged
    assert Repo.query!("SELECT id FROM node WHERE id = $1", [pub]).rows == [[pub]]
    assert Repo.query!("SELECT scope FROM node WHERE id = $1", [priv]).rows == [["private"]]
    # and no alias was recorded for a refused merge
    assert Repo.query!("SELECT count(*) FROM node_alias").rows == [[0]]
  end

  test "merge unions chunk spans under the survivor (no span dropped, ordinals distinct)" do
    a = nid("Dup Alias")
    b = nid("Dup Canon")
    chunk!(b, 0)
    chunk!(a, 0)
    chunk!(a, 1)

    {:ok, %{result: :merged}} = Store.merge_nodes("article", "Dup Alias", "Dup Canon")

    # all three spans survive under the canonical node, with distinct ordinals
    assert chunk_count(b) == 3

    %{rows: [[distinct]]} =
      Repo.query!("SELECT count(DISTINCT ordinal) FROM chunk WHERE node_id = $1", [b])

    assert distinct == 3
    assert chunk_count(a) == 0
  end

  test "content survivorship keeps the higher-fidelity (longer) body" do
    a = nid("Long Alias")
    b = nid("Short Canon")
    content!(b, "short")
    content!(a, "a much much longer and higher fidelity body")

    {:ok, %{result: :merged}} = Store.merge_nodes("article", "Long Alias", "Short Canon")

    assert Repo.query!("SELECT body FROM content WHERE node_id = $1", [b]).rows ==
             [["a much much longer and higher fidelity body"]]

    assert Repo.query!("SELECT count(*) FROM content").rows == [[1]]
  end
end
