defmodule Swarm.Repo.Migrations.SsoGroupMap do
  use Ecto.Migration

  def up do
    create table(:sso_group_map, primary_key: false) do
      add(:provider, :text, null: false)
      add(:incoming_group, :text, null: false)

      add(:our_group_id, references(:access_group, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(unique_index(:sso_group_map, [:provider, :incoming_group]))

    execute(
      """
      INSERT INTO sso_group_map (provider, incoming_group, our_group_id)
      SELECT 'keycloak', id, id
        FROM access_group
       WHERE source = 'idp'
      ON CONFLICT DO NOTHING
      """,
      ""
    )
  end

  def down do
    drop(table(:sso_group_map))
  end
end
