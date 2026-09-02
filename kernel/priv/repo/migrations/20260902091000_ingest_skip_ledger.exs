defmodule Swarm.Repo.Migrations.IngestSkipLedger do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS ingest_skip (
      id bigserial PRIMARY KEY,
      connector text NOT NULL,
      source text NOT NULL,
      source_ref text NOT NULL,
      reason text NOT NULL,
      occurred_at timestamptz NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS ingest_skip_connector_ref_reason_idx
    ON ingest_skip (connector, source_ref, reason)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS ingest_skip_source_reason_idx
    ON ingest_skip (source, reason, occurred_at DESC)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS ingest_skip")
  end
end
