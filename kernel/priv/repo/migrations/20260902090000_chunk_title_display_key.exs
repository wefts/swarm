defmodule Swarm.Repo.Migrations.ChunkTitleDisplayKey do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION chunk_mirror_from_node() RETURNS trigger AS $$
    BEGIN
      SELECT n.scope, coalesce(nullif(n.provenance->>'display_key', ''), n.key)
        INTO STRICT NEW.scope, NEW.title
        FROM node n
       WHERE n.id = NEW.node_id;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION node_propagate_to_chunk() RETURNS trigger AS $$
    BEGIN
      IF NEW.scope IS DISTINCT FROM OLD.scope OR
         NEW.key IS DISTINCT FROM OLD.key OR
         NEW.provenance IS DISTINCT FROM OLD.provenance THEN
        UPDATE chunk
           SET scope = NEW.scope,
               title = coalesce(nullif(NEW.provenance->>'display_key', ''), NEW.key)
         WHERE node_id = NEW.id;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS node_propagate_to_chunk_au ON node")

    execute("""
    CREATE TRIGGER node_propagate_to_chunk_au AFTER UPDATE OF scope, key, provenance ON node
    FOR EACH ROW EXECUTE FUNCTION node_propagate_to_chunk();
    """)

    execute("""
    UPDATE chunk c
       SET title = coalesce(nullif(n.provenance->>'display_key', ''), n.key)
      FROM node n
     WHERE n.id = c.node_id
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION chunk_mirror_from_node() RETURNS trigger AS $$
    BEGIN
      SELECT n.scope, n.key INTO STRICT NEW.scope, NEW.title FROM node n WHERE n.id = NEW.node_id;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

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

    execute("DROP TRIGGER IF EXISTS node_propagate_to_chunk_au ON node")

    execute("""
    CREATE TRIGGER node_propagate_to_chunk_au AFTER UPDATE OF scope, key ON node
    FOR EACH ROW EXECUTE FUNCTION node_propagate_to_chunk();
    """)

    execute("""
    UPDATE chunk c
       SET title = n.key
      FROM node n
     WHERE n.id = c.node_id
    """)
  end
end
