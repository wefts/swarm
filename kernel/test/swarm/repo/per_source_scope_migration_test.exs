Code.require_file("../../../priv/repo/migrations/20260709090000_per_source_scope.exs", __DIR__)

defmodule Swarm.Repo.PerSourceScopeMigrationTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Repo
  alias Swarm.Repo.Migrations.PerSourceScope

  @group_id "per-source-scope-test"

  # This test calls apply_down! directly, which narrows the CHECK constraints + stamps schema v9 —
  # a SCHEMA change that GraphCase's TRUNCATE does not undo, so it would pollute every test that runs
  # afterward (src:* writes → check_violation; stamped_version → 9). Restore the migrated schema
  # (widened CHECK + v10, as `ecto.migrate` left it at suite start) on exit. Data is truncated anyway.
  setup do
    on_exit(fn -> PerSourceScope.apply_up!(Swarm.Repo) end)
    :ok
  end

  test "up attributes per-source scopes and down round-trips group-only seed" do
    seed = seed_group_only_graph!()

    assert scope_counts() == %{"group" => 5}
    assert edge_scope_counts() == %{"group" => 5}
    assert group_scopes() == ["group"]

    assert :ok = PerSourceScope.apply_up!(Repo)

    assert node_scope(seed.wiki) == "src:wiki"
    assert node_scope(seed.ldap) == "src:ldap"
    assert node_scope(seed.derived) == "src:wiki"
    assert node_scope(seed.orphan) == "group"
    assert node_scope(seed.marker) == "public"

    assert edge_scope(seed.same_src_edge) == "src:wiki"
    assert edge_scope(seed.src_group_edge) == "private"

    rewritten_group_scopes = group_scopes()
    assert "src:wiki" in rewritten_group_scopes
    assert "src:ldap" in rewritten_group_scopes

    # `group` is KEPT (transitional) so an admin cohort still sees unattributable left-group nodes.
    assert "group" in rewritten_group_scopes

    assert :ok = PerSourceScope.apply_down!(Repo)

    # Nodes + group grants fully round-trip. Edges: `down` NEVER converts private→group (that is the
    # only rollback move that could leak — council codex+gemini), so the cross-src edge that `up`
    # clamped to `private` STAYS private; the 4 src:* edges revert to group. Full restoration of the
    # clamped edge is via the pre-migration snapshot, not `down`.
    assert scope_counts() == %{"group" => 5}
    assert edge_scope_counts() == %{"group" => 4, "private" => 1}
    assert group_scopes() == ["group"]
  end

  defp seed_group_only_graph! do
    Repo.query!("DELETE FROM group_scope_map WHERE group_id = $1", [@group_id])
    Repo.query!("DELETE FROM access_group WHERE id = $1", [@group_id])

    Repo.query!("INSERT INTO access_group (id, source) VALUES ($1, 'local')", [@group_id])

    Repo.query!("INSERT INTO group_scope_map (group_id, scopes) VALUES ($1, ARRAY['group'])", [
      @group_id
    ])

    wiki = insert_node!("article", "wiki:Paris")
    ldap = insert_node!("user_ref", "ldap:alice")
    derived = insert_node!("concept", "derived:wiki-alias")
    orphan = insert_node!("concept", "orphan:no-origin")
    marker = insert_node!("concept", "who:kind:person")

    wiki_marker = insert_edge!(wiki, marker, "is_a")
    ldap_marker = insert_edge!(ldap, marker, "is_a")
    same_src_edge = insert_edge!(wiki, derived, "mentions")
    src_group_edge = insert_edge!(wiki, orphan, "related_to")
    orphan_marker = insert_edge!(orphan, marker, "is_a")

    insert_provenance!(wiki_marker, "wiki:page:paris", "2026-07-01 00:00:00Z")
    insert_provenance!(ldap_marker, "ldap:directory:alice", "2026-07-01 00:01:00Z")
    insert_provenance!(same_src_edge, "enrich:origin:node:#{wiki}", "2026-07-01 00:02:00Z", wiki)
    insert_provenance!(src_group_edge, "unknown:unattributed", "2026-07-01 00:03:00Z")
    insert_provenance!(orphan_marker, "unknown:marker-link", "2026-07-01 00:04:00Z")

    %{
      wiki: wiki,
      ldap: ldap,
      derived: derived,
      orphan: orphan,
      marker: marker,
      same_src_edge: same_src_edge,
      src_group_edge: src_group_edge
    }
  end

  defp insert_node!(type, key) do
    Repo.query!(
      "INSERT INTO node (type, key, scope) VALUES ($1, $2, 'group') RETURNING id",
      [type, key]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_edge!(src, dst, type) do
    Repo.query!(
      """
      INSERT INTO edge (src, dst, type, visibility_scope, seen_count)
      VALUES ($1, $2, $3, 'group', 1)
      RETURNING id
      """,
      [src, dst, type]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_provenance!(edge_id, origin, seen_at, source_node_id \\ nil) do
    {:ok, dt, _} = DateTime.from_iso8601(seen_at)

    Repo.query!(
      """
      INSERT INTO edge_provenance (edge_id, provenance, origin, seen_at, source_node_id)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [edge_id, "#{origin}:event", origin, dt, source_node_id]
    )
  end

  defp node_scope(id) do
    Repo.query!("SELECT scope FROM node WHERE id = $1", [id]).rows
    |> hd()
    |> hd()
  end

  defp edge_scope(id) do
    Repo.query!("SELECT visibility_scope FROM edge WHERE id = $1", [id]).rows
    |> hd()
    |> hd()
  end

  defp scope_counts do
    Repo.query!("SELECT scope, count(*) FROM node GROUP BY scope").rows
    |> Map.new(fn [scope, count] -> {scope, count} end)
  end

  defp edge_scope_counts do
    Repo.query!("SELECT visibility_scope, count(*) FROM edge GROUP BY visibility_scope").rows
    |> Map.new(fn [scope, count] -> {scope, count} end)
  end

  defp group_scopes do
    Repo.query!("SELECT scopes FROM group_scope_map WHERE group_id = $1", [@group_id]).rows
    |> hd()
    |> hd()
    |> Enum.sort()
  end
end
