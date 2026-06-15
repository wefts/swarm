defmodule Swarm.Repo.Migrations.EmbeddingDim1024 do
  use Ecto.Migration

  # Switch the embedding space to bge-m3 (1024-dim, multilingual). No vectors
  # exist yet, so dropping/re-adding the column is a clean change. `dim` comes
  # from the single config source (`:swarm, :embedding`); `down` restores the
  # prior nomic-embed-text dimension (768).

  def up do
    dim = Application.get_env(:swarm, :embedding, dim: 1024)[:dim] || 1024
    recreate_vec(dim)
  end

  def down do
    recreate_vec(768)
  end

  defp recreate_vec(dim) do
    execute("DROP INDEX IF EXISTS node_vec_hnsw")
    execute("ALTER TABLE node DROP COLUMN IF EXISTS vec")
    execute("ALTER TABLE node ADD COLUMN vec vector(#{dim})")
    execute("CREATE INDEX node_vec_hnsw ON node USING hnsw (vec vector_cosine_ops)")
  end
end
