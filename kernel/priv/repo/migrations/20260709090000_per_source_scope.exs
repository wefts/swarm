defmodule Swarm.Repo.Migrations.PerSourceScope do
  use Ecto.Migration

  @src_scope_re ~r/^src:[a-z0-9_-]+$/
  @max_inherit_iterations 10

  def up do
    apply_up!(repo())
  end

  def down do
    apply_down!(repo())
  end

  def apply_up!(repo) do
    widen_scope_constraints!(repo)
    public_markers = public_markers!(repo)
    IO.puts("per_source_scope: marker nodes moved group->public=#{public_markers}")

    {updated_by_src, left_group} = attribute_group_nodes!(repo)

    for {src, count} <- Enum.sort(updated_by_src) do
      IO.puts("per_source_scope: nodes moved group->#{src}=#{count}")
    end

    IO.puts("per_source_scope: nodes left group=#{left_group}")

    private_edges = recompute_edge_visibility!(repo)
    IO.puts("per_source_scope: edges moved group->private=#{private_edges}")

    maps = rewrite_group_scope_map_up!(repo)
    IO.puts("per_source_scope: group_scope_map rows rewritten=#{maps}")

    repo.query!("UPDATE graph_schema_meta SET version = 10 WHERE id = 1")
    IO.puts("per_source_scope: graph_schema_meta version=10")

    :ok
  end

  def apply_down!(repo) do
    maps = rewrite_group_scope_map_down!(repo)
    IO.puts("per_source_scope down: group_scope_map rows rewritten=#{maps}")

    # Council (codex+gemini, 2026-07-08): `down` NEVER converts `private`→`group`. That is the only
    # rollback move that could LEAK (widen), so it is forbidden — narrowing (leaving a clamped edge
    # `private`) is always safe. Cross-`src` edges that `up` clamped to `private` therefore STAY
    # `private` after `down`; the authoritative full restore is the pre-migration SNAPSHOT (see the RUN
    # order in board/doing/ps-2-plan.md). `down` only undoes the moves provably reversible without an
    # audit table: `src:*`→group and marker→group.
    src_edges =
      repo.query!("UPDATE edge SET visibility_scope = 'group' WHERE visibility_scope ~ '^src:'").num_rows

    IO.puts("per_source_scope down: edges moved src->group=#{src_edges}")

    IO.puts(
      "per_source_scope down: private edges LEFT UNTOUCHED (snapshot is the authoritative full-restore)"
    )

    nodes =
      repo.query!("""
      UPDATE node
         SET scope = 'group'
       WHERE scope ~ '^src:'
          OR (
            scope = 'public'
            AND type = 'concept'
            AND (key LIKE 'who:kind:%' OR key LIKE 'net:kind:%')
          )
      """).num_rows

    IO.puts("per_source_scope down: nodes restored to group=#{nodes}")

    restore_scope_constraints!(repo)
    repo.query!("UPDATE graph_schema_meta SET version = 9 WHERE id = 1")
    IO.puts("per_source_scope down: graph_schema_meta version=9")

    # On staging the authoritative rollback is the pre-migration snapshot. This
    # down is the structural inverse that round-trips a group-only dataset.
    :ok
  end

  def origin_to_src(origin) when is_binary(origin) do
    case origin |> String.split(":", parts: 2) |> List.first() do
      "wiki" -> "src:wiki"
      "mediawiki" -> "src:wiki"
      "wikipedia" -> "src:wiki"
      "confluence" -> "src:confluence"
      "iac" -> "src:iac"
      "ldap" -> "src:ldap"
      "enrich" -> :inherit
      "synonymy" -> :inherit
      _ -> :unknown
    end
  end

  def origin_to_src(_), do: :unknown

  def glb(scope, scope), do: scope
  def glb("private", _), do: "private"
  def glb(_, "private"), do: "private"
  def glb("public", scope), do: scope
  def glb(scope, "public"), do: scope
  def glb(_, _), do: "private"

  defp widen_scope_constraints!(repo) do
    repo.query!("ALTER TABLE node DROP CONSTRAINT IF EXISTS node_scope_vocab")
    repo.query!("ALTER TABLE edge DROP CONSTRAINT IF EXISTS edge_scope_vocab")

    repo.query!("""
    ALTER TABLE node
      ADD CONSTRAINT node_scope_vocab
      CHECK (scope IN ('private','public','group') OR scope ~ '^src:[a-z0-9_-]+$')
    """)

    repo.query!("""
    ALTER TABLE edge
      ADD CONSTRAINT edge_scope_vocab
      CHECK (visibility_scope IN ('private','public','group') OR visibility_scope ~ '^src:[a-z0-9_-]+$')
    """)

    IO.puts("per_source_scope: widened node/edge scope CHECK constraints")
  end

  defp restore_scope_constraints!(repo) do
    repo.query!("ALTER TABLE node DROP CONSTRAINT IF EXISTS node_scope_vocab")
    repo.query!("ALTER TABLE edge DROP CONSTRAINT IF EXISTS edge_scope_vocab")

    repo.query!("""
    ALTER TABLE node
      ADD CONSTRAINT node_scope_vocab
      CHECK (scope IN ('private','group','public'))
    """)

    repo.query!("""
    ALTER TABLE edge
      ADD CONSTRAINT edge_scope_vocab
      CHECK (visibility_scope IN ('private','group','public'))
    """)

    IO.puts("per_source_scope down: restored three-value node/edge scope CHECK constraints")
  end

  defp public_markers!(repo) do
    repo.query!("""
    UPDATE node
       SET scope = 'public'
     WHERE scope = 'group'
       AND type = 'concept'
       AND (key LIKE 'who:kind:%' OR key LIKE 'net:kind:%')
    """).num_rows
  end

  defp attribute_group_nodes!(repo) do
    group_ids =
      repo.query!("SELECT id FROM node WHERE scope = 'group'")
      |> Map.fetch!(:rows)
      |> List.flatten()
      |> MapSet.new()

    rows =
      repo.query!("""
      SELECT n.id, coalesce(ep.origin, ep.provenance) AS origin, ep.seen_at, ep.source_node_id
        FROM node n
        JOIN edge e ON e.src = n.id OR e.dst = n.id
        JOIN edge_provenance ep ON ep.edge_id = e.id
       WHERE n.scope = 'group'
      """).rows

    content_scopes =
      rows
      |> Enum.reduce(%{}, fn [node_id, origin, seen_at, _source_node_id], acc ->
        case origin_to_src(origin) do
          src when is_binary(src) -> keep_earliest_src(acc, node_id, seen_at, src)
          _ -> acc
        end
      end)
      |> Map.new(fn {node_id, {_seen_at, src}} -> {node_id, src} end)

    inherit_edges =
      rows
      |> Enum.filter(fn [_node_id, origin, _seen_at, source_node_id] ->
        origin_to_src(origin) == :inherit and not is_nil(source_node_id)
      end)
      |> Enum.group_by(&hd/1, fn [_node_id, _origin, seen_at, source_node_id] ->
        {seen_at, source_node_id}
      end)
      |> Map.new(fn {node_id, anchors} ->
        {node_id, Enum.sort(anchors, &earlier_tuple?/2)}
      end)

    assignments = inherit_fixpoint(group_ids, content_scopes, inherit_edges)

    counts =
      assignments
      |> Enum.group_by(fn {_node_id, src} -> src end, fn {node_id, _src} -> node_id end)
      |> Map.new(fn {src, ids} ->
        repo.query!("UPDATE node SET scope = $1 WHERE id = ANY($2::bigint[])", [src, ids])
        {src, length(ids)}
      end)

    left_group =
      repo.query!("SELECT count(*) FROM node WHERE scope = 'group'").rows
      |> hd()
      |> hd()

    {counts, left_group}
  end

  defp keep_earliest_src(acc, node_id, seen_at, src) do
    Map.update(acc, node_id, {seen_at, src}, fn {old_seen_at, old_src} ->
      cond do
        earlier?(seen_at, old_seen_at) -> {seen_at, src}
        # Deterministic tiebreak on equal seen_at (council: avoid nondeterministic attribution) —
        # both are valid srcs; pick the lexicographically smaller so a re-run is stable.
        equal_time?(seen_at, old_seen_at) and src < old_src -> {seen_at, src}
        true -> {old_seen_at, old_src}
      end
    end)
  end

  defp equal_time?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp equal_time?(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b) == :eq
  defp equal_time?(a, b), do: a == b

  defp inherit_fixpoint(group_ids, initial_assignments, inherit_edges) do
    Enum.reduce_while(1..@max_inherit_iterations, initial_assignments, fn _iteration,
                                                                          assignments ->
      next =
        group_ids
        |> Enum.reject(&Map.has_key?(assignments, &1))
        |> Enum.reduce(assignments, fn node_id, acc ->
          inherited =
            inherit_edges
            |> Map.get(node_id, [])
            |> Enum.find_value(fn {_seen_at, source_node_id} ->
              src = Map.get(acc, source_node_id)
              if valid_src_scope?(src), do: src
            end)

          if inherited, do: Map.put(acc, node_id, inherited), else: acc
        end)

      if map_size(next) == map_size(assignments), do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp valid_src_scope?(scope) when is_binary(scope), do: Regex.match?(@src_scope_re, scope)
  defp valid_src_scope?(_), do: false

  defp earlier_tuple?({seen_at_a, _source_a}, {seen_at_b, _source_b}),
    do: earlier?(seen_at_a, seen_at_b)

  defp earlier?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :lt

  defp earlier?(%NaiveDateTime{} = a, %NaiveDateTime{} = b),
    do: NaiveDateTime.compare(a, b) == :lt

  defp earlier?(a, b), do: a < b

  defp recompute_edge_visibility!(repo) do
    repo.query!("""
    WITH changed AS (
      UPDATE edge e
         SET visibility_scope = (
           CASE
             WHEN s.scope = d.scope THEN s.scope
             WHEN s.scope = 'private' OR d.scope = 'private' THEN 'private'
             WHEN s.scope = 'public' THEN d.scope
             WHEN d.scope = 'public' THEN s.scope
             ELSE 'private'
           END)
        FROM node s, node d
       WHERE e.src = s.id
         AND e.dst = d.id
         AND e.visibility_scope = 'group'
       RETURNING e.visibility_scope
    )
    SELECT count(*) FROM changed WHERE visibility_scope = 'private'
    """).rows
    |> hd()
    |> hd()
  end

  defp rewrite_group_scope_map_up!(repo) do
    repo.query!("""
    UPDATE group_scope_map
       SET scopes = coalesce((
         SELECT array_agg(DISTINCT x)
           FROM unnest(
             array_remove(scopes, 'group') ||
             coalesce((SELECT array_agg(DISTINCT scope) FROM node WHERE scope ~ '^src:'), '{}'::text[])
           ) x
       ), '{}'::text[])
     WHERE 'group' = ANY(scopes)
    """).num_rows
  end

  defp rewrite_group_scope_map_down!(repo) do
    repo.query!("""
    UPDATE group_scope_map
       SET scopes = (
         SELECT array_agg(DISTINCT x)
           FROM unnest(
             ARRAY(SELECT DISTINCT x FROM unnest(scopes) x WHERE x !~ '^src:') || ARRAY['group']
           ) x
       )
     WHERE EXISTS (SELECT 1 FROM unnest(scopes) x WHERE x ~ '^src:')
    """).num_rows
  end
end
