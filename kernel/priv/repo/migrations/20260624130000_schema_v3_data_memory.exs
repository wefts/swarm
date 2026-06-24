defmodule Swarm.Repo.Migrations.SchemaV3DataMemory do
  use Ecto.Migration

  # Stamp the graph-schema version to 3 — the data-memory-model epoch (swarm
  # ADR-14): the content/chunk side-store (prior migration) plus the closed
  # node-type vocabulary now enforced at the `Swarm.Graph.Contract` boundary.
  #
  # The type vocabulary is enforced at the app boundary + changeset, NOT by a DB
  # CHECK: unlike the 3-value scope vocab (small, stable → worth ossifying in DDL),
  # the node-type set is expected to grow as connectors land, and each growth is an
  # app-side bump. A DB CHECK would force a migration for every vocabulary addition
  # with no extra safety over the boundary that all writers already pass through.

  def up do
    execute("UPDATE graph_schema_meta SET version = 3 WHERE id = 1")
  end

  def down do
    execute("UPDATE graph_schema_meta SET version = 2 WHERE id = 1")
  end
end
