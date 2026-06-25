defmodule Swarm.Repo.Migrations.EvidenceOrigin do
  use Ecto.Migration

  # Schema v3 → v4 — evidential origin (workspace ADR-13). Reinforcement and
  # corroboration must count distinct *evidential origins*, not distinct *emission
  # instances*. `edge_provenance.provenance` stays the per-event dedup key (the
  # ADR-9 endogenous-loop guard); `origin` is the NEW axis: the source identity a
  # connector derives from content, stable across re-emissions of the same fact.
  #
  # `edge.seen_count` is redefined from `count(*)` (distinct events) to
  # `count(DISTINCT origin)` (distinct origins). Legacy rows carry NULL origin, so
  # the recompute falls back to the provenance identity (`coalesce(origin,
  # provenance)`) — every existing edge keeps exactly the count it had (one origin
  # per event = today's behaviour); none loses corroboration.

  def up do
    alter table(:edge_provenance) do
      add(:origin, :text)
    end

    # Back the distinct-origin count with an index; the unique guard stays
    # (edge_id, provenance) — origin is an attribute of the event, not a dedup key.
    create(index(:edge_provenance, [:edge_id, :origin], name: :edge_provenance_origin_idx))

    # Recompute seen_count over distinct origins (coalesce so legacy NULL origin
    # falls back to the provenance identity → no edge loses count).
    execute("""
    UPDATE edge SET seen_count = sub.c
      FROM (
        SELECT edge_id, count(DISTINCT coalesce(origin, provenance)) AS c
          FROM edge_provenance GROUP BY edge_id
      ) sub
     WHERE edge.id = sub.edge_id
    """)

    execute("UPDATE graph_schema_meta SET version = 4 WHERE id = 1")
  end

  def down do
    drop(index(:edge_provenance, [:edge_id, :origin], name: :edge_provenance_origin_idx))

    # Restore the pre-v4 count (distinct provenance events) before dropping origin.
    execute("""
    UPDATE edge SET seen_count = sub.c
      FROM (
        SELECT edge_id, count(DISTINCT provenance) AS c
          FROM edge_provenance GROUP BY edge_id
      ) sub
     WHERE edge.id = sub.edge_id
    """)

    alter table(:edge_provenance) do
      remove(:origin)
    end

    execute("UPDATE graph_schema_meta SET version = 3 WHERE id = 1")
  end
end
