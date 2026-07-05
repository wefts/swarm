defmodule Swarm.Repo.Migrations.EdgeStepOrdinal do
  use Ecto.Migration

  # Workspace ADR-17 (world-map, procedure representation): a `has_step` edge carries
  # the step's position via a dedicated **nullable `step_ordinal`** on `edge` (NULL for
  # every non-step edge). Reconciled 2026-07-05: the `edge` table has no generic
  # property/JSONB map (the spec's "property map" was wrong), and overloading
  # weight/reliability would corrupt their meaning — so a minimal, reversible column,
  # no join on the read path. Bumps the ADR-4 graph schema version 5 → 6.

  def up do
    alter table(:edge) do
      add(:step_ordinal, :smallint)
    end

    execute("UPDATE graph_schema_meta SET version = 6 WHERE id = 1")
  end

  def down do
    execute("UPDATE graph_schema_meta SET version = 5 WHERE id = 1")
    alter(table(:edge), do: remove(:step_ordinal))
  end
end
