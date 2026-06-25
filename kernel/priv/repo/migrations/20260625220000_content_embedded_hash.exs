defmodule Swarm.Repo.Migrations.ContentEmbeddedHash do
  use Ecto.Migration

  # Write-amplification bound for node-vec / chunk embedding (swarm ADR-14 §7).
  # `content.body_hash` is the CURRENT body's hash; `embedded_hash` records the
  # body hash that the node's chunks + `node.vec` were last embedded from. When a
  # `content_added` signal re-fires on an UNCHANGED body (same hash), the worker
  # skips the ~per-window embed instead of re-segmenting + re-calling the embedder +
  # re-aggregating — the costly path that the at-least-once tailer would otherwise
  # repeat. A changed body (or `:force`, e.g. a model change) re-embeds.
  #
  # `content` is the stateless side-store, not the node/edge graph contract, so no
  # graph-schema version bump (cf. node_alias / watermark).

  def up do
    alter table(:content) do
      add(:embedded_hash, :text)
    end
  end

  def down do
    alter table(:content) do
      remove(:embedded_hash)
    end
  end
end
