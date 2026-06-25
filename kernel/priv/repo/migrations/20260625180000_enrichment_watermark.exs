defmodule Swarm.Repo.Migrations.EnrichmentWatermark do
  use Ecto.Migration

  # Durable enrichment watermark (workspace ADR-13 / EOS-4 §1a). Records that a
  # node was enriched and under WHICH content + policy + model, so re-seeing it
  # does not re-pay the ~120 s extraction. Content-sensitive + invalidatable
  # (codex): a changed body (`content_hash`), a bumped `policy_version`/`model`, or
  # a non-`fresh` state triggers re-enrichment; an unchanged fresh node does not.
  #
  # Auxiliary table — NOT part of the node/edge graph contract, so no
  # `graph_schema_meta` version bump (cf. node_alias / outbox / dead_letter).
  # The enriched unit is the node itself (its body is the source), so `node_id` is
  # the key; the claims it writes carry origin = that node's identity.

  def up do
    create table(:enrichment_watermark, primary_key: false) do
      add(:node_id, references(:node, on_delete: :delete_all), null: false, primary_key: true)
      add(:content_hash, :text, null: false)
      add(:policy_version, :integer, null: false)
      add(:model, :text, null: false)
      # Generation counter (the convergence-guard half is EW-5); 0 for now.
      add(:generation, :integer, null: false, default: 0)
      add(:state, :text, null: false, default: "fresh")
      add(:enriched_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:enrichment_watermark, :enrichment_watermark_state,
        check: "state IN ('fresh','stale','retry','error')"
      )
    )
  end

  def down do
    drop(table(:enrichment_watermark))
  end
end
