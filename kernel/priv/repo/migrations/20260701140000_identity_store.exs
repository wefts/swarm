defmodule Swarm.Repo.Migrations.IdentityStore do
  use Ecto.Migration

  # Workspace ADR-16 step 1 — the kernel identity store. The kernel owns the
  # minimal *authorization* record (uuid + login + emails + identity-links +
  # group/scope grants + roles) and is the sole authority; the channel (hive)
  # owns authentication only (password hashes, OIDC, sessions) and never reads
  # these tables. Credentials + IdP secrets never live here.
  #
  # Auxiliary tables (like `deliberation`) — NOT graph tables, so no graph-schema
  # version bump and no node FK. The person-as-data projection (step 7) is a graph
  # `node` on the SAME uuid; it is deliberately separate from this auth record.
  #
  # Physical names dodge the Postgres reserved words `user`/`group` (which are also
  # the `USER`/`CURRENT_USER`/`GROUP` keywords — a bare `user` in raw SQL silently
  # means the DB role, a security-adjacent footgun in a codebase that writes raw
  # SQL). So: `app_user`, `access_group`. The membership/map/grant names are the
  # spec's. UUIDs: `app_user`/`role_grant` ids are app-minted UUIDv7 (time-ordered
  # index locality, ADR-16 D1); child-row ids default to core `gen_random_uuid()`.

  def up do
    create table(:app_user, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      # login = the IdP uid (Smile `penta`) — the login handle AND the match handle.
      add(:login, :text, null: false)
      add(:first_name, :text)
      add(:last_name, :text)
      add(:nickname, :text)
      add(:status, :text, null: false, default: "invited")
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
      add(:updated_at, :timestamptz, null: false, default: fragment("now()"))
      add(:last_login_at, :timestamptz)
    end

    create(unique_index(:app_user, [:login]))

    create(
      constraint(:app_user, :app_user_status_vocab,
        check: "status IN ('invited','active','disabled','deleted')"
      )
    )

    create table(:user_email, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:user_id, references(:app_user, type: :uuid, on_delete: :delete_all), null: false)
      add(:email, :text, null: false)
      add(:verified_at, :timestamptz)
      add(:is_primary, :boolean, null: false, default: false)
      add(:added_at, :timestamptz, null: false, default: fragment("now()"))
    end

    # Email is NOT identity, but is unique across users (one address, one owner).
    create(unique_index(:user_email, [:email]))
    create(index(:user_email, [:user_id]))

    create table(:identity_link, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:user_id, references(:app_user, type: :uuid, on_delete: :delete_all), null: false)
      add(:provider, :text, null: false)
      # The IdP's STABLE `sub` — the account-linking match key (never email).
      add(:subject, :text, null: false)
      add(:verified_at, :timestamptz)
      add(:linked_at, :timestamptz, null: false, default: fragment("now()"))
    end

    # SSO login → find-or-create → ONE uuid: (provider, subject) is the identity.
    create(unique_index(:identity_link, [:provider, :subject]))
    create(index(:identity_link, [:user_id]))

    create table(:access_group, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:source, :text, null: false)
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:access_group, :access_group_source_vocab, check: "source IN ('idp','local')")
    )

    create table(:user_group, primary_key: false) do
      add(:user_id, references(:app_user, type: :uuid, on_delete: :delete_all), null: false)

      add(:group_id, references(:access_group, type: :text, on_delete: :delete_all), null: false)

      add(:source, :text, null: false, default: "idp")
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(unique_index(:user_group, [:user_id, :group_id]))
    # scope resolution joins membership → scope-map by group_id.
    create(index(:user_group, [:group_id]))

    create table(:group_scope_map, primary_key: false) do
      add(:group_id, references(:access_group, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      # default-deny: no map (or empty) ⇒ the group confers no scopes.
      add(:scopes, {:array, :text}, null: false, default: fragment("'{}'::text[]"))
    end

    create table(:role_grant, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:user_id, references(:app_user, type: :uuid, on_delete: :delete_all), null: false)
      add(:role, :text, null: false)
      # source-agnostic: direct / group / sso_group confer identically (ADR-16 D7).
      add(:source, :text, null: false)
      add(:granted_by, :uuid)
      add(:granted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:role_grant, :role_grant_role_vocab, check: "role IN ('admin','superadmin')")
    )

    create(
      constraint(:role_grant, :role_grant_source_vocab,
        check: "source IN ('direct','group','sso_group')"
      )
    )

    create(unique_index(:role_grant, [:user_id, :role, :source]))
    create(index(:role_grant, [:user_id]))
  end

  def down do
    drop(table(:role_grant))
    drop(table(:group_scope_map))
    drop(table(:user_group))
    drop(table(:access_group))
    drop(table(:identity_link))
    drop(table(:user_email))
    drop(table(:app_user))
  end
end
