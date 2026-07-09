defmodule Swarm.Repo.Migrations.NodeDoNotMerge do
  use Ecto.Migration

  # World-map master plan S4 (identity foundations; decorrelated review — codex/gemini: resolve
  # identity BEFORE the first human dataset, else duplicate actors accumulate). The positive side
  # already exists (`node_alias` folds alias→canonical; `merge_nodes`; ER propose/confirm). This
  # adds the NEGATIVE side: a DO-NOT-MERGE assertion — "(type, key_a) is NOT the same entity as
  # (type, key_b)" — so entity-resolution + `merge_nodes` never wrongly collapse two distinct
  # entities (two people/hosts named "core"). A wrong merge is catastrophic + hard to un-merge, so
  # a durable block is the safe guard once people/services arrive.
  #
  # Symmetric: stored normalized (key_a < key_b) so the pair is order-independent + deduped.
  # Bumps the ADR-4 schema version 8 -> 9.

  def up do
    create table(:node_do_not_merge, primary_key: false) do
      add(:type, :text, null: false)
      add(:key_a, :text, null: false)
      add(:key_b, :text, null: false)
      add(:reason, :text)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    # normalized (key_a < key_b) → one row per unordered pair
    create(unique_index(:node_do_not_merge, [:type, :key_a, :key_b], name: :node_do_not_merge_pair_idx))

    execute("UPDATE graph_schema_meta SET version = 9 WHERE id = 1")
  end

  def down do
    execute("UPDATE graph_schema_meta SET version = 8 WHERE id = 1")
    drop(table(:node_do_not_merge))
  end
end
