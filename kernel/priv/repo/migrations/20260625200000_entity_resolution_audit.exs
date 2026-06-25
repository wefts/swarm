defmodule Swarm.Repo.Migrations.EntityResolutionAudit do
  use Ecto.Migration

  # Audit trail for soft entity-resolution decisions (swarm ADR-13 §3.2, ER-3).
  # Contamination (a FALSE merge) is the hard, hard-to-reverse failure mode, so
  # every proposal decision is recorded with its NON-SENSITIVE features (node ids,
  # cosine, lexical overlap, model, decision) — NEVER the keys (entity surface forms
  # are content). This lets an operator inspect why a merge happened, tune the
  # thresholds (ADR-8), and tell whether a failure came from proposal/confirm/merge,
  # before turning soft-match on for real (council, codex).
  #
  # No node FK: a merged-away node is deleted, but the audit must OUTLIVE it (that's
  # the point). Auxiliary table — no graph-schema version bump.

  def up do
    create table(:entity_resolution_audit) do
      add(:left_id, :bigint, null: false)
      add(:right_id, :bigint, null: false)
      add(:cosine, :float, null: false)
      add(:lex, :float, null: false)
      add(:model, :text, null: false)
      # 'rejected' | 'confirmed_merged' | 'confirmed_noop'
      add(:decision, :text, null: false)
      # the surviving (canonical) node id when a merge happened
      add(:into_id, :bigint)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(index(:entity_resolution_audit, [:decision]))
  end

  def down do
    drop(table(:entity_resolution_audit))
  end
end
