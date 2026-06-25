defmodule Swarm.Repo.Migrations.EnrichmentDecision do
  use Ecto.Migration

  # Enrichment priority-decision audit (CTC-2 prerequisite). `Priority.explain` is
  # computed + logged but not persisted, so a hot run yields no priority-calibration
  # dataset. This mirrors `entity_resolution_audit`: per acted-on candidate, the
  # score components + the decision — NON-SENSITIVE features only (node ids/scores,
  # never content). The operator's hot run then has the data to calibrate the
  # reward-gate weights/threshold (ADR-8) from real decisions.
  #
  # Bounded per pass (≤ max_per_pass rows) — the scheduler-action audit. A full
  # below-threshold score distribution is a separate calibration score-dump (CTC-2
  # analyzer), not per-pass. Auxiliary table — no graph-schema version bump.

  def up do
    create table(:enrichment_decision) do
      add(:node_id, :bigint, null: false)
      add(:generation, :integer, null: false)
      add(:novelty, :boolean, null: false)
      add(:central, :float, null: false)
      add(:criticality, :float, null: false)
      add(:score, :float, null: false)
      add(:threshold, :float, null: false)
      # 'enriched' | 'locked' (another pass held it) | 'skipped' (worker no-op)
      add(:decision, :text, null: false)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(index(:enrichment_decision, [:decision]))
  end

  def down do
    drop(table(:enrichment_decision))
  end
end
