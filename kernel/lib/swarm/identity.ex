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

  alias Swarm.Graph.Contract
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

  @doc """
  The guarded wire-facing JIT path (ADR-16 D3, `ProvisionActor`) — NOT a raw
  `upsert_from_claims/1` (council codex+gemini):

    * **Resurrect guard**: a `disabled`/`deleted` account is never reactivated,
      refreshed, or group-synced by a login — `{:error, :inactive}` (the RPC
      collapses it to UNAUTHENTICATED; no disabled-account oracle). An `invited`
      account IS promoted by its first authenticated login (the invite flow).
    * **Collision guard**: a NEW `(provider, subject)` whose login is already
      taken by a different identity is refused loud (`{:error, :login_taken}`)
      — never auto-linked (login-string linking is the account-takeover shape;
      the 6b.6 groot lockout was exactly a silent collision-skip). Linking two
      providers to one uuid stays an explicit admin action.
    * **Race-safe create** (`ON CONFLICT (login) DO NOTHING`): a concurrent
      double-provision of the SAME identity converges on the winner's row; a
      lost race against a DIFFERENT identity is a collision, never a 500.
  """
  @spec provision_from_claims(claims()) :: {:ok, user()} | {:error, :inactive | :login_taken}
  def provision_from_claims(claims) do
    case user_by_link(claims.provider, claims.subject) do
      %{status: s} when s in ["disabled", "deleted"] -> {:error, :inactive}
      %{} -> upsert_from_claims(claims)
      nil -> provision_new(claims)
    end
  end

  @spec provision_new(claims()) :: {:ok, user()} | {:error, :login_taken}
  defp provision_new(claims) do
    case insert_if_login_free(claims) do
      :created ->
        upsert_from_claims(claims)

      :conflict ->
        # Either a concurrent twin of the SAME identity won the race (proceed —
        # idempotent), or the login belongs to a different identity (refuse).
        case user_by_link(claims.provider, claims.subject) do
          %{} -> upsert_from_claims(claims)
          nil -> {:error, :login_taken}
        end
    end
  end

  @spec insert_if_login_free(claims()) :: :created | :conflict
  defp insert_if_login_free(claims) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        id = uuid7()

        res =
          Repo.query!(
            """
            INSERT INTO app_user (id, login, status, last_login_at)
            VALUES ($1, $2, 'active', now())
            ON CONFLICT (login) DO NOTHING
            """,
            [cast_to_uuid(id), claims.login]
          )

        if res.num_rows == 1 do
          Repo.query!(
            """
            INSERT INTO identity_link (user_id, provider, subject, verified_at)
            VALUES ($1, $2, $3, now())
            """,
            [cast_to_uuid(id), claims.provider, claims.subject]
          )

          :created
        else
          :conflict
        end
      end)

    outcome
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

  # ListUsers is bounded BY CONTRACT (council: gemini) — enforced in the SQL, not
  # in memory; the wire `limit` is clamped into (0, @list_users_cap].
  @list_users_cap 500

  @doc """
  The user roster for an admin console (admin-cleanup epic): each row aggregates
  roles, groups and identity-link providers. Tombstones (status=deleted) are
  excluded unless `include_deleted: true` (council: normal operator workflows must
  not act on deleted identities). Supports literal case-insensitive substring
  search over names/login and offset paging. Deterministic order (login, id),
  SQL-bounded. Returns `{rows, total}` where `total` is pre-page count.
  """
  @spec list_users(keyword()) :: {[map()], non_neg_integer()}
  def list_users(opts \\ []) do
    include_deleted = Keyword.get(opts, :include_deleted, false)
    limit = opts |> Keyword.get(:limit, 0) |> clamp_limit()
    offset = opts |> Keyword.get(:offset, 0) |> clamp_offset()
    query = opts |> Keyword.get(:query) |> query_pattern()
    query_absent? = is_nil(query)

    rows =
      Repo.query!(
        """
        SELECT u.id, u.login, u.first_name, u.last_name, u.nickname, u.status, u.last_login_at,
               coalesce(array_agg(DISTINCT r.role) FILTER (WHERE r.role IS NOT NULL), '{}'),
               coalesce(array_agg(DISTINCT g.group_id) FILTER (WHERE g.group_id IS NOT NULL), '{}'),
               coalesce(array_agg(DISTINCT l.provider) FILTER (WHERE l.provider IS NOT NULL), '{}'),
               count(*) OVER()
          FROM app_user u
          LEFT JOIN role_grant r ON r.user_id = u.id
          LEFT JOIN user_group g ON g.user_id = u.id
          LEFT JOIN identity_link l ON l.user_id = u.id
         WHERE ($1 OR u.status <> 'deleted')
           AND ($2 OR u.login ILIKE $3 ESCAPE '\\'
                   OR u.first_name ILIKE $3 ESCAPE '\\'
                   OR u.last_name ILIKE $3 ESCAPE '\\'
                   OR u.nickname ILIKE $3 ESCAPE '\\')
         GROUP BY u.id, u.login, u.first_name, u.last_name, u.nickname, u.status, u.last_login_at
         ORDER BY u.login, u.id
         LIMIT $4 OFFSET $5
        """,
        [include_deleted, query_absent?, query || "%", limit, offset]
      ).rows

    users =
      Enum.map(rows, fn [
                          id,
                          login,
                          first,
                          last,
                          nick,
                          status,
                          last_login,
                          roles,
                          groups,
                          providers,
                          _total
                        ] ->
        %{
          id: cast_uuid(id),
          login: login,
          first_name: first,
          last_name: last,
          nickname: nick,
          status: status,
          last_login_at: last_login,
          roles: roles,
          groups: groups,
          providers: providers
        }
      end)

    total =
      case rows do
        [[_, _, _, _, _, _, _, _, _, _, n] | _] -> n
        [] -> 0
      end

    {users, total}
  end

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @list_users_cap, do: n
  defp clamp_limit(_), do: @list_users_cap

  defp clamp_offset(n) when is_integer(n) and n > 0, do: n
  defp clamp_offset(_), do: 0

  defp query_pattern(q) when is_binary(q) do
    case String.trim(q) do
      "" -> nil
      trimmed -> "%" <> escape_like(trimmed) <> "%"
    end
  end

  defp query_pattern(_), do: nil

  defp escape_like(q) do
    q
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
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

  @doc "Identity providers linked to a user."
  @spec providers_for(String.t()) :: [String.t()]
  def providers_for(id) do
    Repo.query!(
      "SELECT DISTINCT provider FROM identity_link WHERE user_id = $1 ORDER BY provider",
      [cast_to_uuid(id)]
    ).rows
    |> List.flatten()
  end

  @doc """
  Full admin-visible view for one active/non-deleted user, including emails.
  Returns `nil` for an unknown or tombstoned user.
  """
  @spec get_user_view(String.t()) :: map() | nil
  def get_user_view(id) do
    case get_user(id) do
      nil ->
        nil

      %{status: "deleted"} ->
        nil

      user ->
        %{
          id: user.id,
          login: user.login,
          first_name: user.first_name,
          last_name: user.last_name,
          nickname: user.nickname,
          status: user.status,
          last_login_at: user.last_login_at,
          roles: roles_for(user.id),
          groups: groups_for(user.id),
          providers: providers_for(user.id),
          emails: user.id |> emails_for() |> Enum.map(& &1.email)
        }
    end
  end

  @doc """
  The scopes a user is granted: the **authenticated baseline `public`** plus the
  scopes **derived** from their groups via `group_scope_map` (unioned, deduped).
  Default-deny holds for everything ABOVE public: unmapped groups add nothing.

  The baseline restores the channel's documented, council-reviewed semantic
  ("ALWAYS includes public; groups add more" — `web_channel/auth.scopes_for`)
  that the D9 kernel-derivation move silently dropped: with an unseeded
  `group_scope_map`, every signed actor derived `[]` and the ENTIRE knowledge
  base was invisible (found live on staging, 2026-07-03). `public` is public
  knowledge — any authenticated, active actor may read it; this also matches
  the anonymous/legacy path (`norm_scopes([]) ⇒ ["public"]`). A JIT-provisioned
  subject with no groups therefore lands exactly at public.

  `private` is clamped out even if present in the map (the belt behind the
  `put_group_scopes/2` grant boundary — a legacy/raw-SQL row can never confer
  the per-user privacy scope).
  """
  @spec scopes_for(String.t()) :: [String.t()]
  def scopes_for(id) do
    derived =
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
      |> Enum.reject(&(&1 == "private"))

    Enum.uniq(["public" | derived])
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
  The scopes a group grant may confer: the Contract vocabulary MINUS `private`.
  `private` is the default-deny floor AND the per-user chat-privacy mechanism
  (person-scope-leak-guard) — conferring it to any group would expose every
  user's private facts, so it can never be granted.
  """
  @spec grantable_scopes() :: [String.t()]
  def grantable_scopes, do: Contract.scopes() -- ["private"]

  @doc """
  Ensure a group exists and set its conferred scopes (the config-seeding
  primitive; the audited admin-mutable path is ADR-16 step 5). Idempotent.

  Validates at this — the deepest — grant boundary: every scope must be in
  `grantable_scopes/0` (Contract vocabulary, `private` hard-denied); on
  violation nothing is written. Seeding callers must pattern-match `:ok =` so
  a rejected seed fails loud rather than leaving the group scopeless (council
  gemini).
  """
  @spec put_group_scopes(String.t(), [String.t()]) :: :ok | {:error, :ungrantable_scope}
  def put_group_scopes(group_id, scopes) do
    if Enum.all?(scopes, &(&1 in grantable_scopes())) do
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
    else
      {:error, :ungrantable_scope}
    end
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
