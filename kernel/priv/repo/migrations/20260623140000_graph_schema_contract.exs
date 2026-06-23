defmodule Swarm.Repo.Migrations.GraphSchemaContract do
  use Ecto.Migration

  # swarm ADR-4: the graph schema is a versioned public contract. A singleton row
  # stamps the integer graph-schema version so migrations have a compatibility
  # anchor and `Swarm.Graph.Contract.stamped_version/0` can read it. Bump the
  # version (and add a round-trip test) on every node/edge schema change.

  def up do
    create table(:graph_schema_meta, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:version, :integer, null: false)
    end

    create(constraint(:graph_schema_meta, :graph_schema_meta_singleton, check: "id = 1"))

    execute("INSERT INTO graph_schema_meta (id, version) VALUES (1, 1)")

    # Defense-in-depth (swarm ADR-4): the scope vocabulary is enforced at the DB
    # too, so a non-`Store` writer (raw SQL, psql, a misbehaving plugin with DB
    # creds) cannot insert an out-of-vocabulary scope. The cross-row visibility
    # invariant (edge ≤ endpoints) needs other rows, so it stays an app-boundary
    # check + a documented future trigger — a CHECK cannot express it.
    create(constraint(:node, :node_scope_vocab, check: "scope IN ('private','group','public')"))

    create(
      constraint(:edge, :edge_scope_vocab,
        check: "visibility_scope IN ('private','group','public')"
      )
    )
  end

  def down do
    drop(constraint(:edge, :edge_scope_vocab))
    drop(constraint(:node, :node_scope_vocab))
    drop(table(:graph_schema_meta))
  end
end
