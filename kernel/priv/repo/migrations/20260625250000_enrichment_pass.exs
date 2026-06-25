defmodule Swarm.Repo.Migrations.EnrichmentPass do
  use Ecto.Migration

  # Per-pass enrichment score-distribution summary (CTC-2 prereq, council/codex).
  # The per-row `enrichment_decision` audit only records ACTED-ON (worth-it top-N)
  # candidates — a right-truncated sample that answers "what did we spend work on"
  # but NOT "what threshold should we have used" (it never sees below-threshold
  # scores). This one row per pass captures the full candidate score distribution
  # (percentiles + counts) cheaply, so the threshold is calibratable from real runs
  # even without a separate score-dump. Scores only — no content.

  def up do
    create table(:enrichment_pass) do
      add(:generation, :integer, null: false)
      add(:candidate_count, :integer, null: false)
      add(:worth_it_count, :integer, null: false)
      add(:score_min, :float, null: false)
      add(:score_p50, :float, null: false)
      add(:score_p90, :float, null: false)
      add(:score_p99, :float, null: false)
      add(:score_max, :float, null: false)
      add(:threshold, :float, null: false)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end
  end

  def down do
    drop(table(:enrichment_pass))
  end
end
