defmodule Swarm.Repo.Migrations.ChunkBm25LexicalArm do
  use Ecto.Migration

  # ADR-0016: the pg_search (Tantivy BM25) lexical arm. A bm25 index is single-table
  # and can only filter/boost on its OWN columns, so `scope` and `title` (= node.key)
  # are DENORMALIZED onto `chunk` — the only way to get filter-before-rank on scope
  # (RESULT no-leak; NB a shared bm25 index's IDF is corpus-global, so bm25 scores are
  # not term-existence-safe until the `bm25-index-hardening` gate) and a title
  # field-boost inside one index.
  #
  # This refines (does not overturn) ADR-14 §1's "chunk carries no scope": `node.scope`
  # stays the AUTHORITATIVE source — the retrieval query still joins it as the outer
  # belt, so even a hypothetically stale mirror cannot leak a result. The mirror is a
  # trigger-maintained cache kept consistent SYNCHRONOUSLY within the same transaction
  # as the node write (no drift window), purely to make the bm25 scan efficient +
  # term-existence-safe. The bm25 index itself is created only where pg_search is
  # installed (guarded), so a plain-pgvector deployment migrates cleanly and runs the
  # native arm.

  def up do
    # --- mirror columns (node.scope / node.key → chunk.scope / chunk.title) ---
    alter table(:chunk) do
      add :scope, :text
      add :title, :text
    end

    # Backfill existing rows.
    execute("""
    UPDATE chunk c SET scope = n.scope, title = n.key FROM node n WHERE n.id = c.node_id
    """)

    # A chunk's mirror is set from its node on INSERT and whenever its node_id changes.
    # STRICT: a chunk whose node doesn't exist is a bug (the FK forbids it) — raise
    # rather than silently write a NULL scope (a NULL mirror must never reach the index).
    execute("""
    CREATE OR REPLACE FUNCTION chunk_mirror_from_node() RETURNS trigger AS $$
    BEGIN
      SELECT n.scope, n.key INTO STRICT NEW.scope, NEW.title FROM node n WHERE n.id = NEW.node_id;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER chunk_mirror_biu BEFORE INSERT OR UPDATE OF node_id ON chunk
    FOR EACH ROW EXECUTE FUNCTION chunk_mirror_from_node();
    """)

    # A node's scope/key change propagates to all its chunks (same transaction).
    execute("""
    CREATE OR REPLACE FUNCTION node_propagate_to_chunk() RETURNS trigger AS $$
    BEGIN
      IF NEW.scope IS DISTINCT FROM OLD.scope OR NEW.key IS DISTINCT FROM OLD.key THEN
        UPDATE chunk SET scope = NEW.scope, title = NEW.key WHERE node_id = NEW.id;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER node_propagate_to_chunk_au AFTER UPDATE OF scope, key ON node
    FOR EACH ROW EXECUTE FUNCTION node_propagate_to_chunk();
    """)

    # The mirror is now populated (backfill + triggers) — forbid a NULL SCOPE so a
    # chunk can never enter the bm25 index without a scope (fail-closed at the schema;
    # node.scope is itself NOT NULL, so this is always satisfiable). `title` mirrors
    # node.key, which CAN be NULL (keyless worker-minted nodes — they carry no chunks
    # in practice), so title stays nullable.
    execute("ALTER TABLE chunk ALTER COLUMN scope SET NOT NULL")

    # --- the bm25 index, only where pg_search is available (guarded) ---
    # Field-boosted body+title, scope as a filter field → filter-before-rank in-index.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_search') THEN
        CREATE EXTENSION IF NOT EXISTS pg_search;
        EXECUTE 'CREATE INDEX IF NOT EXISTS chunk_bm25 ON chunk USING bm25 (id, text, title, scope) WITH (key_field=''id'')';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS chunk_bm25")
    execute("DROP TRIGGER IF EXISTS node_propagate_to_chunk_au ON node")
    execute("DROP FUNCTION IF EXISTS node_propagate_to_chunk()")
    execute("DROP TRIGGER IF EXISTS chunk_mirror_biu ON chunk")
    execute("DROP FUNCTION IF EXISTS chunk_mirror_from_node()")

    alter table(:chunk) do
      remove :scope
      remove :title
    end
  end
end
