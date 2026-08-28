defmodule Swarm.Repo.Migrations.ChunkBm25ScopeKeyword do
  use Ecto.Migration

  # ADR-0016 × ADR-20: the bm25 `scope` field must be an EXACT (keyword) term.
  #
  # `chunk_bm25` indexed `scope` with pg_search's default text tokenizer. That was
  # harmless while the scope vocabulary was single-token (`public|group|private`) — the
  # exact `paradedb.term('scope', s)` filter in `Swarm.Graph.Retrieval` matched the one
  # token. ADR-20 replaced `group` with `src:<uuid>`, which the default tokenizer splits
  # into `src`, `7a540f8f`, `6f1d`, … — so the exact filter can NEVER match a Project
  # source scope and the bm25 arm silently returns nothing for every Project-scoped
  # chunk (observed on staging 2026-08-28: `term('scope','src')` hit 8728 chunks,
  # `term('scope','src:<uuid>')` hit 0). This is item 2 of
  # `board/todo/bm25-index-hardening`, now forced rather than deferred.
  #
  # Fix: rebuild the index declaring `scope` with the `keyword` tokenizer (stored
  # verbatim, one term per value). Same guard as the original: only where pg_search is
  # installed; a plain-pgvector deployment is a no-op and keeps running the native arm.
  # `text`/`title` keep the default tokenizer (they are ranked, not filtered).

  @index_sql ~s|CREATE INDEX IF NOT EXISTS chunk_bm25 ON chunk USING bm25 (id, text, title, scope) WITH (key_field=''id'', text_fields=''{"scope": {"tokenizer": {"type": "keyword"}}}'')|

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_search') THEN
        DROP INDEX IF EXISTS chunk_bm25;
        EXECUTE '#{@index_sql}';
      END IF;
    END $$;
    """)
  end

  def down do
    # Back to the pre-ADR-20 shape (default tokenizer on every field). Under ADR-20
    # scopes this makes the bm25 arm blind again — only meaningful together with the
    # `project_access` down.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_search') THEN
        DROP INDEX IF EXISTS chunk_bm25;
        EXECUTE 'CREATE INDEX IF NOT EXISTS chunk_bm25 ON chunk USING bm25 (id, text, title, scope) WITH (key_field=''id'')';
      END IF;
    END $$;
    """)
  end
end
