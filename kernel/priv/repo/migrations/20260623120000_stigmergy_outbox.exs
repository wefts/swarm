defmodule Swarm.Repo.Migrations.StigmergyOutbox do
  use Ecto.Migration

  # The stigmergy signal (swarm ADR-2): a transactional outbox. Graph writes append
  # a row here IN THE SAME TRANSACTION, so the change and its signal are atomic. A
  # single tailer consumes rows in `seq` order; gaps are in-flight or rolled-back.

  def change do
    create table(:outbox, primary_key: false) do
      # Monotonic ordering + gap key. A rolled-back insert burns a seq → a gap the
      # tailer resolves (wait) or proves rolled-back (skip after timeout).
      add :seq, :bigserial, primary_key: true
      add :change, :text, null: false
      add :target_key, :text, null: false
      add :payload, :map, null: false, default: %{}
      # Stable, work-derived key for crash-safe idempotent re-processing.
      add :idem_key, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:outbox, [:change])

    # Single-row cursor: the tailer's committed position.
    create table(:outbox_cursor, primary_key: false) do
      add :id, :integer, primary_key: true
      add :position, :bigint, null: false, default: 0
    end

    create constraint(:outbox_cursor, :outbox_cursor_singleton, check: "id = 1")

    execute(
      "INSERT INTO outbox_cursor (id, position) VALUES (1, 0)",
      "DELETE FROM outbox_cursor WHERE id = 1"
    )
  end
end
