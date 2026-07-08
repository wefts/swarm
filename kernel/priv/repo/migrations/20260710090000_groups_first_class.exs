defmodule Swarm.Repo.Migrations.GroupsFirstClass do
  use Ecto.Migration

  def up do
    alter table(:access_group) do
      add(:name, :text)
      add(:description, :text)
    end

    execute("UPDATE access_group SET name = id WHERE name IS NULL", "")

    create table(:group_role, primary_key: false) do
      add(:group_id, references(:access_group, type: :text, on_delete: :delete_all), null: false)
      add(:role, :text, null: false)
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(unique_index(:group_role, [:group_id, :role]))

    create(
      constraint(:group_role, :group_role_vocab, check: "role IN ('user','admin','superadmin')")
    )
  end

  def down do
    drop(table(:group_role))

    alter table(:access_group) do
      remove(:name)
      remove(:description)
    end
  end
end
