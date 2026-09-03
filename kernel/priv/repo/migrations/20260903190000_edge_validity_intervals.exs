defmodule Swarm.Repo.Migrations.EdgeValidityIntervals do
  @moduledoc """
  Schema v13 — bitemporal validity intervals (`swarm/docs/design/temporal-fact-model.md`).

  An `edge` row stays the TIMELESS identity of a fact (subject, relation, object); this table
  records WHEN the fact was true according to the source (`valid_from` / `valid_to` /
  `observed_at` = valid time) separately from when Swarm learned it (`recorded_at` /
  `closed_at` = transaction time). One edge may own several disjoint intervals (a VM that moves
  A→B→A). Rows partition by the asserting `source` (a site-qualified run identity such as
  `proxmox:casa`) so absence reconciliation closes only what that source asserted, while
  supersession works on the world-level `supersession_key` across sources.

  Shape decided with Gemini as decorrelated critic (2026-09-03): separate table (not columns on
  `edge`, not per-emission `edge_provenance`), denormalised `supersession_key` + partial index,
  DB-enforced non-overlap per (edge, source) via a GiST exclusion constraint, no `superseded_by`
  pointer (causality is reconstructed at read time). Legacy edges with no interval rows read as
  UNDATED — nothing is retroactively timed.
  """
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

    execute("""
    CREATE TABLE edge_validity (
      id               bigserial PRIMARY KEY,
      edge_id          bigint NOT NULL REFERENCES edge(id) ON DELETE CASCADE,
      supersession_key text NOT NULL,
      source           text NOT NULL,
      origin           text,
      valid_from       timestamptz,
      valid_to         timestamptz,
      observed_at      timestamptz,
      closed_reason    text,
      absent_at        timestamptz,
      recorded_at      timestamptz NOT NULL DEFAULT now(),
      updated_at       timestamptz NOT NULL DEFAULT now(),
      closed_at        timestamptz,
      CONSTRAINT edge_validity_ordered CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
      CONSTRAINT edge_validity_closed_shape CHECK (
        (valid_to IS NULL AND closed_reason IS NULL AND closed_at IS NULL)
        OR (valid_to IS NOT NULL AND closed_reason IS NOT NULL AND closed_at IS NOT NULL)
      ),
      CONSTRAINT edge_validity_closed_reason_vocab CHECK (closed_reason IS NULL OR closed_reason IN ('superseded', 'absent', 'manual')),
      CONSTRAINT edge_validity_absent_shape CHECK (absent_at IS NULL OR closed_reason = 'absent'),
      CONSTRAINT edge_validity_no_overlap EXCLUDE USING gist (
        edge_id WITH =,
        source WITH =,
        tstzrange(coalesce(valid_from, '-infinity'::timestamptz), coalesce(valid_to, 'infinity'::timestamptz), '[)') WITH &&
      )
    )
    """)

    execute(
      "CREATE INDEX edge_validity_open_key_idx ON edge_validity (supersession_key) WHERE valid_to IS NULL"
    )

    execute("CREATE INDEX edge_validity_key_idx ON edge_validity (supersession_key, valid_from)")
    execute("CREATE INDEX edge_validity_edge_idx ON edge_validity (edge_id)")

    execute(
      "CREATE INDEX edge_validity_source_open_idx ON edge_validity (source, updated_at) WHERE valid_to IS NULL"
    )

    execute("UPDATE graph_schema_meta SET version = 13 WHERE id = 1")
  end

  def down do
    execute("DROP TABLE IF EXISTS edge_validity")
    execute("UPDATE graph_schema_meta SET version = 12 WHERE id = 1")
  end
end
