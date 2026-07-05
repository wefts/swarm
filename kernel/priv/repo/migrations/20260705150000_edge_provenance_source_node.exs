defmodule Swarm.Repo.Migrations.EdgeProvenanceSourceNode do
  use Ecto.Migration

  # Workspace ADR-17 §2 / ADR-13 (source-node ghost-purge, GC/merge contract —
  # blackboard board/research/gc-ghost-purge-blackboard.md). A derived edge records
  # its evidential SOURCE only as an opaque `origin` string ("enrich:origin:node:{N}").
  # When that source node is merged/deleted, the derived edge lingers with an origin
  # pointing at a dead source — a "ghost" that can stitch a phantom procedure step.
  # `merge_nodes` (Store) must purge those edges, but must NOT parse a worker-private
  # string convention (council, unanimous): add a STRUCTURAL nullable
  # `source_node_id` so Store filters on `WHERE source_node_id = alias_id`.
  #
  # NO foreign key (council, codex): an `ON DELETE CASCADE` would bypass the required
  # orphan-edge deletion + seen_count recompute; the purge is explicit in the merge
  # transaction (before the alias node is deleted). Plain indexed column + a defensive
  # periodic GC sweep for legacy/orphaned rows. Bumps the ADR-4 schema version 6 → 7.

  def up do
    alter table(:edge_provenance) do
      add(:source_node_id, :bigint)
    end

    create(index(:edge_provenance, [:source_node_id], name: :edge_provenance_source_node_idx))

    # Backfill from the existing enrichment-origin convention (the migration may know
    # the format once, so the purge is effective for edges written before this column).
    execute("""
    UPDATE edge_provenance
       SET source_node_id = CAST(substring(origin FROM 'enrich:origin:node:([0-9]+)') AS bigint)
     WHERE origin ~ '^enrich:origin:node:[0-9]+$'
    """)

    execute("UPDATE graph_schema_meta SET version = 7 WHERE id = 1")
  end

  def down do
    execute("UPDATE graph_schema_meta SET version = 6 WHERE id = 1")
    drop(index(:edge_provenance, [:source_node_id], name: :edge_provenance_source_node_idx))

    alter table(:edge_provenance) do
      remove(:source_node_id)
    end
  end
end
