defmodule Swarm.Repo.Migrations.EdgeEvidenceKind do
  use Ecto.Migration

  # Schema v4 → v5 — edge-level evidential kind (workspace ADR-13, refines EOS-2).
  # The evidential kind of an assertion (claim vs observation) belongs on the
  # ASSERTION, not on its source node: a relation `(Paris)-[located_in]->(France)`
  # has an entity source, not a claim source, so reading `src_node.kind` as the
  # corroboration kind mis-types LLM extractions. `edge.evidence_kind` carries what
  # the assertion CONTRIBUTES (`node.kind` stays = what the node IS). Default
  # `observation` — the safe, neutral kind, and the correct default for connector-
  # ingested relations (external evidence); the enrichment worker sets `claim`.

  @kinds ~w(observation claim hypothesis coordination lease derived presentation durable_fact)

  def up do
    alter table(:edge) do
      add(:evidence_kind, :text, null: false, default: "observation")
    end

    create(constraint(:edge, :edge_evidence_kind_vocab, check: kind_check()))
    execute("UPDATE graph_schema_meta SET version = 5 WHERE id = 1")
  end

  def down do
    drop(constraint(:edge, :edge_evidence_kind_vocab))
    alter(table(:edge), do: remove(:evidence_kind))
    execute("UPDATE graph_schema_meta SET version = 4 WHERE id = 1")
  end

  defp kind_check do
    list = Enum.map_join(@kinds, ",", &"'#{&1}'")
    "evidence_kind IN (#{list})"
  end
end
