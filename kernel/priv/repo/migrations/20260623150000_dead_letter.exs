defmodule Swarm.Repo.Migrations.DeadLetter do
  use Ecto.Migration

  # T10: poison-trace dead-letter zone. An un-processable ingest event (malformed
  # shape, contract violation, bad timestamp) is quarantined here WITH its reason —
  # never silently dropped, never re-entering to block the pipeline.

  def up do
    create table(:dead_letter) do
      add :payload, :map, null: false, default: %{}
      add :reason, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end
  end

  def down do
    drop table(:dead_letter)
  end
end
