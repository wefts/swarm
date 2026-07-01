defmodule Swarm.Repo.Migrations.AdminActionAudit do
  use Ecto.Migration

  # Workspace ADR-16 step 4 (+ step 5) — the append-only admin-action audit trail.
  # Every privileged cross-user action (break-glass conversation read now; grant /
  # revoke / invite / deactivate / delete in step 5) writes a row here, and for
  # break-glass the row is written BEFORE any data is returned (ADR-16 D6).
  #
  # No FK on actor_id / target_* (plain uuids): an audit trail must OUTLIVE its
  # subjects — same pattern as `entity_resolution_audit`, which deliberately has no
  # node FK. So a deactivated/deleted user's audit history persists (D11).

  def up do
    create table(:admin_action_audit, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:actor_id, :uuid, null: false)
      # read_conversation | grant | revoke | invite | deactivate | delete
      add(:action, :text, null: false)
      add(:target_user_id, :uuid)
      add(:target_conversation_id, :uuid)
      # extra structured context (scope / group / ids) — never secrets.
      add(:detail, :map)
      add(:reason, :text)
      add(:request_id, :text)
      # allowed | denied | not_found
      add(:decision, :text, null: false)
      add(:data_returned, :boolean, null: false, default: false)
      add(:at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(index(:admin_action_audit, [:actor_id, :at]))
    create(index(:admin_action_audit, [:target_user_id, :at]))
  end

  def down do
    drop(table(:admin_action_audit))
  end
end
