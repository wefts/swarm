defmodule Swarm.Repo.Migrations.EdgeProvenanceLineage do
  use Ecto.Migration

  # World-map master plan S1 (evidence-governance spine; decorrelated review 2026-07-07, codex +
  # gemini): corroboration must count DISTINCT UPSTREAM LINEAGE, not distinct origin labels. Three
  # origins derived from ONE upstream (e.g. all wiki-derived, or three mirrors of one stale export)
  # are NOT three independent votes — counting them as such manufactures false confidence.
  #
  # Adds a nullable `lineage` to edge_provenance (the true upstream family) and recomputes
  # `seen_count = count(DISTINCT coalesce(lineage, origin, provenance))`. Writers set `lineage`
  # going forward; the seen_count formula everywhere becomes lineage-aware (Store, Aggregation, GC,
  # Worker, Procedures, Resolver).
  #
  # This migration lands the MECHANISM only: lineage defaults to the origin itself (per-source),
  # so `count(DISTINCT coalesce(lineage, origin, provenance))` == the pre-S1 distinct-origin count
  # — ZERO behavior change, safe. The GRANULARITY POLICY (which origins share an upstream) is a
  # designed S1-step-2: the wiki family must dedup at PAGE level, not "all wiki = 1" (a coarse
  # all-wiki collapse wrongly merged two independent pages' attestations — worker_test caught it);
  # derivation-metadata lineage (scraped-from/generated-by, per codex) is the fuller form.
  # Bumps the ADR-4 schema version 7 -> 8.

  def up do
    alter table(:edge_provenance) do
      add(:lineage, :text)
    end

    create(index(:edge_provenance, [:edge_id, :lineage], name: :edge_provenance_lineage_idx))

    # Backfill: lineage = the origin itself (per-source) — identity, so seen_count is unchanged.
    execute("UPDATE edge_provenance SET lineage = coalesce(origin, provenance)")

    # Recompute every edge's corroboration over distinct lineage.
    execute("""
    UPDATE edge e
       SET seen_count = (
         SELECT count(DISTINCT coalesce(ep.lineage, ep.origin, ep.provenance))
           FROM edge_provenance ep WHERE ep.edge_id = e.id
       )
    """)

    execute("UPDATE graph_schema_meta SET version = 8 WHERE id = 1")
  end

  def down do
    execute("UPDATE graph_schema_meta SET version = 7 WHERE id = 1")
    drop(index(:edge_provenance, [:edge_id, :lineage], name: :edge_provenance_lineage_idx))

    alter table(:edge_provenance) do
      remove(:lineage)
    end

    # Restore the origin-based seen_count.
    execute("""
    UPDATE edge e
       SET seen_count = (
         SELECT count(DISTINCT coalesce(ep.origin, ep.provenance))
           FROM edge_provenance ep WHERE ep.edge_id = e.id
       )
    """)
  end
end
