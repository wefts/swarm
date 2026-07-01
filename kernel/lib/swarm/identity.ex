defmodule Swarm.Identity do
  @moduledoc """
  The kernel identity store (workspace ADR-16, step 1). The kernel owns the
  minimal **authorization** record — `uuid` + `login` + emails + identity-links +
  group/scope grants + roles — and is the sole authority for who-may-do-what. The
  channel (hive) owns **authentication only** (password hashes, OIDC exchange,
  sessions) and never reads these tables.

  Provisioning is **JIT from already-verified claims**: `upsert_from_claims/1`
  takes the OIDC-shaped claim map the channel forwards *after* the kernel has
  cryptographically verified the actor assertion (that verification is ADR-16
  step 2 / Decision 9 — this store trusts its caller to have verified). Matching
  is on the stable `(provider, subject)` link, never on login or email, so an SSO
  login and a later rename resolve to **one** uuid (account-linking).

  Scopes and roles are **derived** here from the kernel's own records
  (`group_scope_map`, `role_grant`) — never taken from a channel-supplied field.
  Default-deny throughout: a group with no scope-map confers nothing; a user with
  no `role_grant` holds no capabilities.

  Credentials and IdP secrets never live here. `identity_link.subject` is the
  opaque IdP `sub`, not a secret; password hashes stay channel-side.
  """

  alias Swarm.Repo

  @type claims :: %{
          required(:provider) => String.t(),
          required(:subject) => String.t(),
          required(:login) => String.t(),
          optional(:first_name) => String.t() | nil,
          optional(:last_name) => String.t() | nil,
          optional(:nickname) => String.t() | nil,
          optional(:emails) => [email_claim()],
          optional(:groups) => [String.t()]
        }
  @type email_claim :: %{
          required(:email) => String.t(),
          optional(:verified) => boolean(),
          optional(:primary) => boolean()
        }
  @type user :: %{
          id: String.t(),
          login: String.t(),
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          nickname: String.t() | nil,
          status: String.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_login_at: DateTime.t() | nil
        }

  # ── UUIDv7 (ADR-16 D1) ────────────────────────────────────────────────

  @doc """
  Mint a UUIDv7 string (lowercase, hyphenated). Layout per RFC 9562: a 48-bit
  Unix-millisecond timestamp in the high bits (time-ordered → index locality),
  the version nibble `7`, the `10` variant, and 74 random bits.
  """
  @spec uuid7() :: String.t()
  def uuid7 do
    ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    <<ms::48, 7::4, rand_a::12, 2::2, rand_b::62>> |> encode_uuid()
  end

  @spec encode_uuid(binary()) :: String.t()
  defp encode_uuid(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    [a, b, c, d, e]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  # ── JIT provisioning ──────────────────────────────────────────────────

  @doc """
  Find-or-create the user for a set of *verified* claims, idempotently, matching
  on `(provider, subject)`. Updates the mutable attributes (login, names),
  promotes `invited → active` on first authenticated login, touches
  `last_login_at`, and reconciles emails + group memberships to the claim set
  (a group dropped from the claims is revoked — default-deny). Returns the user.
  """
  @spec upsert_from_claims(claims()) :: {:ok, user()}
  def upsert_from_claims(claims) do
    {:ok, id} =
      Repo.transaction(fn ->
        user_id = find_or_create_user(claims)
        sync_emails(user_id, Map.get(claims, :emails, []))
        sync_groups(user_id, Map.get(claims, :groups, []))
        user_id
      end)

    {:ok, get_user(id)}
  end

  @spec find_or_create_user(claims()) :: String.t()
  defp find_or_create_user(claims) do
    case Repo.query!(
           "SELECT user_id FROM identity_link WHERE provider = $1 AND subject = $2",
           [claims.provider, claims.subject]
         ) do
      %{rows: [[user_id]]} ->
        update_user(user_id, claims)
        cast_uuid(user_id)

      %{rows: []} ->
        create_user(claims)
    end
  end

  @spec create_user(claims()) :: String.t()
  defp create_user(claims) do
    id = uuid7()

    Repo.query!(
      """
      INSERT INTO app_user (id, login, first_name, last_name, nickname, status, last_login_at)
      VALUES ($1, $2, $3, $4, $5, 'active', now())
      """,
      [
        cast_to_uuid(id),
        claims.login,
        Map.get(claims, :first_name),
        Map.get(claims, :last_name),
        Map.get(claims, :nickname)
      ]
    )

    Repo.query!(
      """
      INSERT INTO identity_link (user_id, provider, subject, verified_at)
      VALUES ($1, $2, $3, now())
      """,
      [cast_to_uuid(id), claims.provider, claims.subject]
    )

    id
  end

  @spec update_user(binary(), claims()) :: :ok
  defp update_user(user_id, claims) do
    # Re-login: refresh mutable attrs, promote invited→active, touch last_login_at.
    Repo.query!(
      """
      UPDATE app_user
         SET login = $2, first_name = $3, last_name = $4, nickname = $5,
             status = CASE WHEN status = 'invited' THEN 'active' ELSE status END,
             last_login_at = now(), updated_at = now()
       WHERE id = $1
      """,
      [
        user_id,
        claims.login,
        Map.get(claims, :first_name),
        Map.get(claims, :last_name),
        Map.get(claims, :nickname)
      ]
    )

    :ok
  end

  @spec sync_emails(String.t(), [email_claim()]) :: :ok
  defp sync_emails(user_id, emails) do
    Enum.each(emails, fn e ->
      verified_at = if Map.get(e, :verified, false), do: "now()", else: "NULL"

      Repo.query!(
        """
        INSERT INTO user_email (user_id, email, verified_at, is_primary)
        VALUES ($1, $2, #{verified_at}, $3)
        ON CONFLICT (email) DO UPDATE
          SET user_id = EXCLUDED.user_id,
              verified_at = COALESCE(user_email.verified_at, EXCLUDED.verified_at),
              is_primary = EXCLUDED.is_primary
        """,
        [cast_to_uuid(user_id), e.email, Map.get(e, :primary, false)]
      )
    end)

    :ok
  end

  @spec sync_groups(String.t(), [String.t()]) :: :ok
  defp sync_groups(user_id, groups) do
    Enum.each(groups, fn g ->
      Repo.query!(
        "INSERT INTO access_group (id, source) VALUES ($1, 'idp') ON CONFLICT (id) DO NOTHING",
        [g]
      )

      Repo.query!(
        """
        INSERT INTO user_group (user_id, group_id, source) VALUES ($1, $2, 'idp')
        ON CONFLICT (user_id, group_id) DO NOTHING
        """,
        [cast_to_uuid(user_id), g]
      )
    end)

    # Revoke memberships no longer asserted (default-deny).
    Repo.query!(
      "DELETE FROM user_group WHERE user_id = $1 AND NOT (group_id = ANY($2))",
      [cast_to_uuid(user_id), groups]
    )

    :ok
  end

  # ── Superadmin seed (the root/uid-0 mechanism, ADR-16 D7) ──────────────

  @doc """
  Idempotently seed a superadmin: a local, active user with the given (vanity)
  UUIDv7 `id` and `login`, plus a `superadmin` `role_grant`. The concrete id +
  login are deployment config (hive seeds them at bootstrap) — the kernel ships
  only the mechanism, never a literal name.
  """
  @spec seed_superadmin(%{id: String.t(), login: String.t()}) :: {:ok, user()}
  def seed_superadmin(%{id: id, login: login}) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO app_user (id, login, status, last_login_at)
          VALUES ($1, $2, 'active', now())
          ON CONFLICT (id) DO UPDATE SET login = EXCLUDED.login, updated_at = now()
          """,
          [cast_to_uuid(id), login]
        )

        Repo.query!(
          """
          INSERT INTO role_grant (user_id, role, source)
          VALUES ($1, 'superadmin', 'direct')
          ON CONFLICT (user_id, role, source) DO NOTHING
          """,
          [cast_to_uuid(id)]
        )

        # A local account resolves via the SAME identity_link path as SSO (uniform
        # resolution): provider "local", subject = login.
        Repo.query!(
          """
          INSERT INTO identity_link (user_id, provider, subject, verified_at)
          VALUES ($1, 'local', $2, now())
          ON CONFLICT (provider, subject) DO NOTHING
          """,
          [cast_to_uuid(id), login]
        )
      end)

    {:ok, get_user(id)}
  end

  # ── Mutations (the audited, cap-gated callers live in Swarm.Admin) ─────

  @doc "Grant a role (idempotent). `source` ∈ direct|group|sso_group."
  @spec grant_role(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def grant_role(user_id, role, source, granted_by \\ nil) do
    Repo.query!(
      """
      INSERT INTO role_grant (user_id, role, source, granted_by)
      VALUES ($1, $2, $3, $4) ON CONFLICT (user_id, role, source) DO NOTHING
      """,
      [cast_to_uuid(user_id), role, source, opt_uuid(granted_by)]
    )

    :ok
  end

  @doc "Revoke a role (all sources)."
  @spec revoke_role(String.t(), String.t()) :: :ok
  def revoke_role(user_id, role) do
    Repo.query!("DELETE FROM role_grant WHERE user_id = $1 AND role = $2", [
      cast_to_uuid(user_id),
      role
    ])

    :ok
  end

  @doc "Add a user to a group (idempotent; ensures the group exists)."
  @spec add_to_group(String.t(), String.t()) :: :ok
  def add_to_group(user_id, group_id) do
    Repo.query!(
      "INSERT INTO access_group (id, source) VALUES ($1, 'local') ON CONFLICT (id) DO NOTHING",
      [group_id]
    )

    Repo.query!(
      """
      INSERT INTO user_group (user_id, group_id, source) VALUES ($1, $2, 'local')
      ON CONFLICT (user_id, group_id) DO NOTHING
      """,
      [cast_to_uuid(user_id), group_id]
    )

    :ok
  end

  @doc "Remove a user from a group."
  @spec remove_from_group(String.t(), String.t()) :: :ok
  def remove_from_group(user_id, group_id) do
    Repo.query!("DELETE FROM user_group WHERE user_id = $1 AND group_id = $2", [
      cast_to_uuid(user_id),
      group_id
    ])

    :ok
  end

  @doc """
  Create an invited local user (no credential — the channel sets the password) with
  a local `identity_link` so local login resolves. `attrs`: `:login` (required),
  `:first_name`, `:last_name`, `:nickname`.
  """
  @spec invite_user(map()) :: {:ok, user()}
  def invite_user(attrs) do
    id = uuid7()
    login = Map.fetch!(attrs, :login)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO app_user (id, login, first_name, last_name, nickname, status)
          VALUES ($1, $2, $3, $4, $5, 'invited')
          """,
          [
            cast_to_uuid(id),
            login,
            Map.get(attrs, :first_name),
            Map.get(attrs, :last_name),
            Map.get(attrs, :nickname)
          ]
        )

        Repo.query!(
          "INSERT INTO identity_link (user_id, provider, subject) VALUES ($1, 'local', $2)",
          [cast_to_uuid(id), login]
        )
      end)

    {:ok, get_user(id)}
  end

  @doc """
  Deactivate an account: `status = disabled` + strip role grants (privilege dies).
  Login is blocked (`Swarm.Actor.resolve` rejects non-active). Group memberships and
  learned content are retained (reversible; D11).
  """
  @spec deactivate_user(String.t()) :: :ok
  def deactivate_user(user_id) do
    Repo.transaction(fn ->
      Repo.query!(
        "UPDATE app_user SET status = 'disabled', updated_at = now() WHERE id = $1",
        [cast_to_uuid(user_id)]
      )

      Repo.query!("DELETE FROM role_grant WHERE user_id = $1", [cast_to_uuid(user_id)])
    end)

    :ok
  end

  @doc """
  Delete an account: `status = deleted` + every login path removed (role grants, group
  memberships, identity links; credential is channel-side). The `app_user` row PERSISTS
  (FK + audit integrity) and learned/derived content persists — this is a self-hosted
  instance, not a right-to-erasure (D11; raw-conversation purge is the deferred policy).
  """
  @spec delete_user(String.t()) :: :ok
  def delete_user(user_id) do
    Repo.transaction(fn ->
      Repo.query!(
        "UPDATE app_user SET status = 'deleted', updated_at = now() WHERE id = $1",
        [cast_to_uuid(user_id)]
      )

      Repo.query!("DELETE FROM role_grant WHERE user_id = $1", [cast_to_uuid(user_id)])
      Repo.query!("DELETE FROM user_group WHERE user_id = $1", [cast_to_uuid(user_id)])
      Repo.query!("DELETE FROM identity_link WHERE user_id = $1", [cast_to_uuid(user_id)])
    end)

    :ok
  end

  # ── Reads (derivation happens here, never from a channel field) ────────

  @doc "Fetch a user by uuid, or `nil`."
  @spec get_user(String.t()) :: user() | nil
  def get_user(id) do
    case Repo.query!(
           """
           SELECT id, login, first_name, last_name, nickname, status,
                  created_at, updated_at, last_login_at
             FROM app_user WHERE id = $1
           """,
           [cast_to_uuid(id)]
         ) do
      %{rows: [row]} -> to_user(row)
      %{rows: []} -> nil
    end
  end

  @doc "Fetch a user by `login`, or `nil`."
  @spec by_login(String.t()) :: user() | nil
  def by_login(login) do
    case Repo.query!(
           """
           SELECT id, login, first_name, last_name, nickname, status,
                  created_at, updated_at, last_login_at
             FROM app_user WHERE login = $1
           """,
           [login]
         ) do
      %{rows: [row]} -> to_user(row)
      %{rows: []} -> nil
    end
  end

  @doc "Emails on record for a user (each `%{email, verified_at, is_primary}`)."
  @spec emails_for(String.t()) :: [
          %{email: String.t(), verified_at: term(), is_primary: boolean()}
        ]
  def emails_for(id) do
    Repo.query!(
      "SELECT email, verified_at, is_primary FROM user_email WHERE user_id = $1 ORDER BY email",
      [cast_to_uuid(id)]
    ).rows
    |> Enum.map(fn [email, verified_at, is_primary] ->
      %{email: email, verified_at: verified_at, is_primary: is_primary}
    end)
  end

  @doc "Group ids a user belongs to."
  @spec groups_for(String.t()) :: [String.t()]
  def groups_for(id) do
    Repo.query!(
      "SELECT group_id FROM user_group WHERE user_id = $1 ORDER BY group_id",
      [cast_to_uuid(id)]
    ).rows
    |> List.flatten()
  end

  @doc """
  The scopes a user is granted, **derived** from their groups via
  `group_scope_map` (unioned, deduped). Default-deny: unmapped groups add nothing.
  """
  @spec scopes_for(String.t()) :: [String.t()]
  def scopes_for(id) do
    Repo.query!(
      """
      SELECT DISTINCT unnest(m.scopes) AS scope
        FROM user_group ug
        JOIN group_scope_map m ON m.group_id = ug.group_id
       WHERE ug.user_id = $1
      """,
      [cast_to_uuid(id)]
    ).rows
    |> List.flatten()
  end

  @doc "The roles a user holds (default-deny — `[]` when none granted)."
  @spec roles_for(String.t()) :: [String.t()]
  def roles_for(id) do
    Repo.query!(
      "SELECT DISTINCT role FROM role_grant WHERE user_id = $1 ORDER BY role",
      [cast_to_uuid(id)]
    ).rows
    |> List.flatten()
  end

  # Role → capability policy (ADR-16 D7). superadmin ⊃ admin, and alone holds the
  # break-glass `read_any_conversation`.
  @admin_caps ~w(manage_access invite_users manage_users)
  @superadmin_caps @admin_caps ++ ~w(read_any_conversation)

  @doc """
  The capabilities a user holds, **derived** from their roles (default-deny — `[]`
  when no role is granted). superadmin ⊃ admin + `read_any_conversation`.
  """
  @spec caps_for(String.t()) :: [String.t()]
  def caps_for(id) do
    id
    |> roles_for()
    |> Enum.flat_map(fn
      "superadmin" -> @superadmin_caps
      "admin" -> @admin_caps
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The user linked to a `(provider, subject)` pair, or `nil`. The resolve lookup."
  @spec user_by_link(String.t(), String.t()) :: user() | nil
  def user_by_link(provider, subject) do
    case Repo.query!(
           "SELECT user_id FROM identity_link WHERE provider = $1 AND subject = $2",
           [provider, subject]
         ) do
      %{rows: [[user_id]]} -> get_user(cast_uuid(user_id))
      %{rows: []} -> nil
    end
  end

  @doc "Total user count."
  @spec count_users() :: non_neg_integer()
  def count_users do
    [[n]] = Repo.query!("SELECT count(*) FROM app_user", []).rows
    n
  end

  @doc """
  Ensure a group exists and set its conferred scopes (the config-seeding
  primitive; the audited admin-mutable path is ADR-16 step 5). Idempotent.
  """
  @spec put_group_scopes(String.t(), [String.t()]) :: :ok
  def put_group_scopes(group_id, scopes) do
    Repo.query!(
      "INSERT INTO access_group (id, source) VALUES ($1, 'local') ON CONFLICT (id) DO NOTHING",
      [group_id]
    )

    Repo.query!(
      """
      INSERT INTO group_scope_map (group_id, scopes) VALUES ($1, $2)
      ON CONFLICT (group_id) DO UPDATE SET scopes = EXCLUDED.scopes
      """,
      [group_id, scopes]
    )

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Postgrex returns a :uuid column as a 16-byte binary; render it as the string form.
  @spec cast_uuid(binary()) :: String.t()
  defp cast_uuid(<<_::128>> = bin), do: encode_uuid(bin)
  defp cast_uuid(str) when is_binary(str), do: str

  # Ecto/Postgrex accepts a hyphenated uuid string as a parameter for a :uuid column
  # via Ecto.UUID.dump/1 → the raw 16 bytes.
  @spec cast_to_uuid(String.t()) :: binary()
  defp cast_to_uuid(str) do
    {:ok, bin} = Ecto.UUID.dump(str)
    bin
  end

  @spec opt_uuid(String.t() | nil) :: binary() | nil
  defp opt_uuid(nil), do: nil
  defp opt_uuid(str), do: cast_to_uuid(str)

  @spec to_user([term()]) :: user()
  defp to_user([
         id,
         login,
         first_name,
         last_name,
         nickname,
         status,
         created_at,
         updated_at,
         last_login_at
       ]) do
    %{
      id: cast_uuid(id),
      login: login,
      first_name: first_name,
      last_name: last_name,
      nickname: nickname,
      status: status,
      created_at: created_at,
      updated_at: updated_at,
      last_login_at: last_login_at
    }
  end
end
