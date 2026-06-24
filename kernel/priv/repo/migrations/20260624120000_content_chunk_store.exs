defmodule Swarm.Repo.Migrations.ContentChunkStore do
  use Ecto.Migration

  # The stateless content/chunk side-store (swarm ADR-14 / data-memory-model §1).
  # The node stays the only evidence-bearing tier; `content` is its raw body and
  # `chunk` is the HNSW-indexed retrieval span. Neither carries a `scope` column —
  # scope is read through `node.scope` (single source of truth, cannot drift) — and
  # neither is ever a graph edge endpoint. Both CASCADE from the node, so deleting a
  # node reaps its body and spans with it (no orphan handle survives).

  def up do
    dim = Application.get_env(:swarm, :embedding, dim: 1024)[:dim] || 1024

    # CONTENT — one row per node that carries text. `node_id` is the PK (1:1 with
    # the node), so the FK + PK together enforce "at most one body per node".
    create table(:content, primary_key: false) do
      add :node_id, references(:node, on_delete: :delete_all), null: false, primary_key: true
      add :body, :text, null: false
      # SHA-256 for exact dedup; a SimHash/MinHash signature for near-dup detection
      # at the observation layer (the ADR-9 lever). Stored as text; opaque here.
      add :body_hash, :text, null: false
      add :source_ref, :text
      add :segmenter, :text, null: false
      add :created_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:content, [:body_hash])

    # CHUNK — one row per retrieval span. No scope column, no edges; never returned
    # without its `node_id` + `ordinal` (the cited-span rule, enforced in code).
    create table(:chunk) do
      add :node_id, references(:node, on_delete: :delete_all), null: false
      add :ordinal, :integer, null: false
      add :text, :text, null: false
      add :vec, :"vector(#{dim})"
      add :embed_model, :text
      add :token_count, :integer

      add :created_at, :timestamptz, null: false, default: fragment("now()")
    end

    # Spans of one node are ordered and unique by ordinal.
    create unique_index(:chunk, [:node_id, :ordinal], name: :chunk_node_ordinal)
    create index(:chunk, [:node_id])

    # Dense arm: HNSW over chunk.vec (cosine), one row per vector.
    execute(
      "CREATE INDEX chunk_vec_hnsw ON chunk USING hnsw (vec vector_cosine_ops)",
      "DROP INDEX chunk_vec_hnsw"
    )

    # Lexical arm: GIN over a `simple`-config tsvector of the span text. `simple`
    # (no stemming/stopwords) keeps it language-agnostic for the multilingual
    # corpus; the retrieval query builds the same tsvector so the index is used.
    execute(
      "CREATE INDEX chunk_text_fts ON chunk USING gin (to_tsvector('simple', text))",
      "DROP INDEX chunk_text_fts"
    )
  end

  def down do
    drop table(:chunk)
    drop table(:content)
  end
end
