defmodule Swarm.Repo.Migrations.Stagnant do
  use Ecto.Migration

  # T13: the stagnation monitor's surface. A trace that no worker handles (the
  # bystander-effect deadlock) or a claimable trace nobody takes is recorded here
  # instead of silently stalling — surfaced for a human / fallback escalation.
  #
  # `(reason, ref)` is UNIQUE: a recurring stall is recorded ONCE (deduped), not
  # once per occurrence — so a high-frequency unhandled change kind cannot flood
  # the table and bury real stalls.

  def up do
    create table(:stagnant) do
      add :reason, :text, null: false
      add :ref, :text, null: false
      add :detail, :text
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:stagnant, [:reason, :ref], name: :stagnant_dedup)
  end

  def down do
    drop table(:stagnant)
  end
end
