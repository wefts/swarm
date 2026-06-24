defmodule Swarm.Repo.Migrations.NodeAliasTable do
  use Ecto.Migration

  # The reversible standing alias table (swarm ADR-14 §3.2 / ADR-13 layer-2
  # remainder). `(type, alias_key) → canonical_key`: `upsert_node` consults it
  # before minting, so a known alias resolves to the canonical node instead of
  # spawning a duplicate. Reversible (delete the row) and audit-friendly
  # (`created_at` + the row itself), preferred over eager collapse. A successful
  # `merge_nodes` records the alias here so the fold becomes standing, not one-shot.

  def up do
    create table(:node_alias, primary_key: false) do
      add :type, :text, null: false, primary_key: true
      add :alias_key, :text, null: false, primary_key: true
      add :canonical_key, :text, null: false
      add :created_at, :timestamptz, null: false, default: fragment("now()")
    end
  end

  def down do
    drop table(:node_alias)
  end
end
