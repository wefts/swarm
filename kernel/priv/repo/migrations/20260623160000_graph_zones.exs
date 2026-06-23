defmodule Swarm.Repo.Migrations.GraphZones do
  use Ecto.Migration

  # T12 (N3 fix): graph zones + claim-vs-observation typing + reward-gated
  # persistence. `node.kind` is the tuple-class/zone (each kind has its own
  # lifecycle); `edge.reward` carries external ground-truth reward so a refuted
  # trace can be reaped regardless of strength. Bumps the ADR-4 schema version 1→2.

  @kinds ~w(observation claim hypothesis coordination lease derived presentation durable_fact)

  def up do
    # Zone / tuple-class. Default `observation` — the safe, neutral kind. An
    # LLM-generated trace is `claim` and must never count as independent evidence.
    alter table(:node) do
      add(:kind, :text, null: false, default: "observation")
    end

    create(constraint(:node, :node_kind_vocab, check: kind_check()))

    # External-reward signal on a trace (T12). 0 = neutral; < 0 = refuted (reaped).
    alter table(:edge) do
      add(:reward, :float, null: false, default: 0.0)
    end

    create(index(:node, [:kind]))

    execute("UPDATE graph_schema_meta SET version = 2 WHERE id = 1")
  end

  def down do
    execute("UPDATE graph_schema_meta SET version = 1 WHERE id = 1")
    drop(index(:node, [:kind]))
    alter(table(:edge), do: remove(:reward))
    drop(constraint(:node, :node_kind_vocab))
    alter(table(:node), do: remove(:kind))
  end

  defp kind_check do
    list = Enum.map_join(@kinds, ",", &"'#{&1}'")
    "kind IN (#{list})"
  end
end
