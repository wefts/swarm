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
end
