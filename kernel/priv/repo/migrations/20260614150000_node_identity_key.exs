defmodule Swarm.Repo.Migrations.NodeIdentityKey do
  use Ecto.Migration

  # Stable external identity for ingestion upsert. NULLs are distinct in a unique
  # index, so keyless nodes (created directly, not ingested) never collide;
  # ingested nodes dedup on (type, key).

  def change do
    alter table(:node) do
      add :key, :text
    end

    create unique_index(:node, [:type, :key], name: :node_identity_key)
  end
end
