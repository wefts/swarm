defmodule Swarm.Repo.Migrations.EnableVectorAndSchemaMeta do
  use Ecto.Migration

  # Baseline migration: enable pgvector and record embedding-namespace stamps
  # (ADR-6). No domain tables yet — the graph schema is Task 02.

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    # One row per embedding namespace: which model produced its vectors, the
    # dimensionality, and whether the (re-)embed run has covered the whole
    # corpus. `status` stays "pending" until a run completes (ADR-6 self-heal).
    create table(:schema_meta, primary_key: false) do
      add :namespace, :text, primary_key: true
      add :model, :text, null: false
      add :dim, :integer, null: false
      add :status, :text, null: false, default: "pending"
      add :note, :text

      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    drop table(:schema_meta)
    execute("DROP EXTENSION IF EXISTS vector")
  end
end
