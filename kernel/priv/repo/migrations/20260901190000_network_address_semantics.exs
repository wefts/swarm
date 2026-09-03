defmodule Swarm.Repo.Migrations.NetworkAddressSemantics do
  use Ecto.Migration

  def up do
    alter table(:node) do
      add(:net_addr, :inet)
      add(:net_range, :cidr)
      add(:net_address_class, :text)
    end

    create(
      constraint(:node, :node_net_address_class,
        check:
          "net_address_class IS NULL OR net_address_class IN ('private','cgnat','loopback','link_local','documentation','multicast','ula','public')"
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION swarm_try_inet(value text)
    RETURNS inet
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
    BEGIN
      RETURN value::inet;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION swarm_try_cidr(value text)
    RETURNS cidr
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
    BEGIN
      RETURN value::cidr;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION swarm_net_address_class(addr inet)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    AS $$
      SELECT CASE
        WHEN addr IS NULL THEN NULL
        WHEN addr <<= inet '10.0.0.0/8'
          OR addr <<= inet '172.16.0.0/12'
          OR addr <<= inet '192.168.0.0/16' THEN 'private'
        WHEN addr <<= inet '100.64.0.0/10' THEN 'cgnat'
        WHEN addr <<= inet '127.0.0.0/8' THEN 'loopback'
        WHEN addr <<= inet '169.254.0.0/16'
          OR addr <<= inet 'fe80::/10' THEN 'link_local'
        WHEN addr <<= inet '192.0.2.0/24'
          OR addr <<= inet '198.51.100.0/24'
          OR addr <<= inet '203.0.113.0/24' THEN 'documentation'
        WHEN addr <<= inet '224.0.0.0/4' THEN 'multicast'
        WHEN addr <<= inet 'fc00::/7' THEN 'ula'
        WHEN addr <<= inet '2000::/3' THEN 'public'
        ELSE 'public'
      END
    $$;
    """)

    execute("""
    UPDATE node
       SET net_addr = swarm_try_inet(substring(key FROM '^net:(?:address|subnet):(.+)$')),
           net_range = swarm_try_cidr(substring(key FROM '^net:(?:address|subnet):(.+)$')),
           net_address_class = swarm_net_address_class(swarm_try_inet(substring(key FROM '^net:(?:address|subnet):(.+)$')))
     WHERE key ~ '^net:(address|subnet):'
    """)

    execute("""
    INSERT INTO edge (
      src, dst, type, visibility_scope, weight, reliability, evidence_kind,
      step_ordinal, seen_count, last_seen, created_at, updated_at
    )
    SELECT e.src,
           e.dst,
           CASE
             WHEN d.net_address_class = 'public' THEN 'has_public_address'
             ELSE 'has_private_address'
           END,
           e.visibility_scope,
           e.weight,
           e.reliability,
           e.evidence_kind,
           NULL,
           0,
           e.last_seen,
           e.created_at,
           e.updated_at
      FROM edge e
      JOIN node d ON d.id = e.dst
     WHERE e.type = 'has_address'
       AND d.net_address_class IS NOT NULL
    ON CONFLICT (src, type, dst, visibility_scope) DO NOTHING
    """)

    execute("""
    WITH classified AS (
      SELECT e.id AS parent_edge_id,
             e.src, e.dst, e.visibility_scope,
             CASE
               WHEN d.net_address_class = 'public' THEN 'has_public_address'
               WHEN d.net_address_class IS NOT NULL THEN 'has_private_address'
               ELSE NULL
             END AS child_type
        FROM edge e
        JOIN node d ON d.id = e.dst
       WHERE e.type = 'has_address'
         AND d.net_address_class IS NOT NULL
    ),
    child_edges AS (
      SELECT c.parent_edge_id, e.id AS child_edge_id
        FROM classified c
        JOIN edge e ON e.src = c.src
                   AND e.dst = c.dst
                   AND e.type = c.child_type
                   AND e.visibility_scope IS NOT DISTINCT FROM c.visibility_scope
    )
    INSERT INTO edge_provenance (edge_id, provenance, origin, lineage, source_node_id, seen_at)
    SELECT ce.child_edge_id, ep.provenance, ep.origin, ep.lineage, ep.source_node_id, ep.seen_at
      FROM child_edges ce
      JOIN edge_provenance ep ON ep.edge_id = ce.parent_edge_id
    ON CONFLICT (edge_id, provenance) DO NOTHING
    """)

    execute("""
    UPDATE edge e
       SET seen_count = sub.seen_count,
           updated_at = now()
      FROM (
        SELECT e.id, count(DISTINCT coalesce(ep.lineage, ep.origin, ep.provenance)) AS seen_count
          FROM edge e
          JOIN edge_provenance ep ON ep.edge_id = e.id
         WHERE e.type IN ('has_private_address', 'has_public_address')
         GROUP BY e.id
      ) sub
     WHERE e.id = sub.id
    """)

    execute(
      "CREATE INDEX node_net_addr_gist ON node USING gist (net_addr inet_ops) WHERE net_addr IS NOT NULL",
      "DROP INDEX IF EXISTS node_net_addr_gist"
    )

    execute(
      "CREATE INDEX node_net_range_gist ON node USING gist (net_range inet_ops) WHERE net_range IS NOT NULL",
      "DROP INDEX IF EXISTS node_net_range_gist"
    )

    execute("UPDATE graph_schema_meta SET version = 12 WHERE id = 1")
  end

  def down do
    execute("DELETE FROM edge WHERE type IN ('has_private_address', 'has_public_address')")
    execute("DROP INDEX IF EXISTS node_net_range_gist")
    execute("DROP INDEX IF EXISTS node_net_addr_gist")
    execute("DROP FUNCTION IF EXISTS swarm_net_address_class(inet)")
    execute("DROP FUNCTION IF EXISTS swarm_try_cidr(text)")
    execute("DROP FUNCTION IF EXISTS swarm_try_inet(text)")

    alter table(:node) do
      remove(:net_address_class)
      remove(:net_range)
      remove(:net_addr)
    end

    execute("UPDATE graph_schema_meta SET version = 11 WHERE id = 1")
  end
end
