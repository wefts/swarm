defmodule Swarm.Repo.Migrations.DeliberationStore do
  use Ecto.Migration

  # Retained panel-vs-judge deliberations (swarm ADR-15). The Consilium verdict is
  # discarded today; this persists it keyed by an opaque `ask_ref` so a past
  # escalated answer can re-open its panel-vs-judge view. Read is owner-gated AND
  # current-scope-gated (the request scopes must still cover the asking scopes — no
  # stale-authorization bypass). NON-anonymous escalations only. GC'd by the ADR-10
  # trace-lifecycle pass (TTL + max-row cap), so no new timer. The panel text is no
  # more sensitive than the answer already delivered to the owner.
  #
  # Auxiliary table (re-servable presentation state) — NOT a graph table, so no
  # graph-schema version bump and no node FK (a deliberation outlives node churn).

  def up do
    create table(:deliberation, primary_key: false) do
      add(:ask_ref, :text, primary_key: true)
      add(:viewer, :text, null: false)
      # The scopes the retrieval ran under (the asking scopes); read requires the
      # current request scopes to COVER these.
      add(:scopes, {:array, :text}, null: false)
      add(:answer, :text, null: false)
      add(:confidence, :float, null: false)
      add(:disagreement, :float, null: false)
      # JSON-encoded [{"model","answer"}, ...] — the raw takes before synthesis.
      add(:panel, :text, null: false)
      add(:judge, :text, null: false)
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
    end

    # GC scans by age; over-cap eviction is oldest-first — both order by created_at.
    create(index(:deliberation, [:created_at]))
  end

  def down do
    drop(table(:deliberation))
  end
end
