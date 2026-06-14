defmodule Swarm.Repo.Migrations.GraphSchema do
  use Ecto.Migration

  # The knowledge-graph substrate with the day-1 invariants baked into the DDL
  # (ADR-1 CAS/fencing, ADR-3 reliability, ADR-5 scope, ADR-6 embed stamp,
  # ADR-9 reinforcement/decay). No domain logic — just nodes, typed edges, the
  # claim primitive, and the confidence/decay fields.

  def up do
    dim = Application.get_env(:swarm, :embedding, dim: 768)[:dim] || 768

    # NODE — everything is a node (user/file/event/concept/task/agent/self/source).
    create table(:node) do
      add :type, :text, null: false
      # Stored embedding (ADR-6); nullable until embedded. One model/space at a
      # time — `embed_model` stamps which namespace produced it.
      add :vec, :"vector(#{dim})"
      add :embed_model, :text
      # Visibility-scope (ADR-5): default-deny is `private`. Index-level pruning,
      # not a per-edge predicate at query time.
      add :scope, :text, null: false, default: "private"
      # Node reliability r_0 * w_source (ADR-3); time decay applied at read.
      add :reliability, :float, null: false, default: 1.0
      add :provenance, :map, null: false, default: %{}
      # Claim/lease columns — a task IS a node (ADR-1/ADR-2 fenced lease).
      add :claimed_by, :text
      add :lease_until, :timestamptz
      add :fence, :bigint, null: false, default: 0

      # `timestamptz` (not naive `timestamp`): store absolute instants so decay
      # `now() - ts` is correct regardless of session tz (tz-aware UTC invariant).
      add :created_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create constraint(:node, :node_reliability_range,
             check: "reliability >= 0 AND reliability <= 1"
           )

    create index(:node, [:scope])
    create index(:node, [:type])

    execute(
      "CREATE INDEX node_vec_hnsw ON node USING hnsw (vec vector_cosine_ops)",
      "DROP INDEX node_vec_hnsw"
    )

    # EDGE — typed relation. Natural key (src, type, dst, visibility_scope);
    # insert-or-increment upsert is reinforcement (ADR-9). Timestamps carry DB
    # defaults because edges are managed via raw SQL (atomic upsert/increment).
    create table(:edge) do
      add :src, references(:node, on_delete: :delete_all), null: false
      add :dst, references(:node, on_delete: :delete_all), null: false
      add :type, :text, null: false
      add :visibility_scope, :text, null: false, default: "private"
      # Stigmergic strength input (ADR-9) vs confidence reliability (ADR-3).
      add :weight, :float, null: false, default: 1.0
      add :reliability, :float, null: false, default: 1.0
      # Distinct-provenance reinforcement count (ADR-9); see edge_provenance.
      add :seen_count, :integer, null: false, default: 0
      add :last_seen, :timestamptz, null: false, default: fragment("now()")
      add :created_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create constraint(:edge, :edge_reliability_range,
             check: "reliability >= 0 AND reliability <= 1"
           )

    create unique_index(:edge, [:src, :type, :dst, :visibility_scope], name: :edge_natural_key)
    create index(:edge, [:src])
    create index(:edge, [:dst])

    # EDGE_PROVENANCE — the mechanical ADR-9 guard: seen_count grows only from
    # provenance-distinct events, never from internal re-detections. One row per
    # (edge, provenance event); seen_count == count of distinct rows.
    create table(:edge_provenance, primary_key: false) do
      add :edge_id, references(:edge, on_delete: :delete_all), null: false
      add :provenance, :text, null: false
      add :seen_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:edge_provenance, [:edge_id, :provenance], name: :edge_provenance_pkey)
  end

  def down do
    drop table(:edge_provenance)
    drop table(:edge)
    drop table(:node)
  end
end
