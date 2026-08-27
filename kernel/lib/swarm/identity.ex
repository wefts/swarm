defmodule Swarm.Identity do
  @moduledoc """
  The kernel identity store (workspace ADR-16 step 1, access model ADR-20). The kernel owns the
  minimal **authorization** record — `uuid` + `login` + emails + identity-links + group
  memberships + Project memberships — and is the sole authority for who-may-see-what and
  who-may-do-what. The channel (hive) owns **authentication only** (password hashes, OIDC
  exchange, sessions) and never reads these tables.

  Provisioning is **JIT from already-verified claims**: `upsert_from_claims/1` takes the
  OIDC-shaped claim map the channel forwards *after* the kernel has cryptographically verified
  the actor assertion (ADR-16 D9 — this store trusts its caller to have verified). Matching is
  on the stable `(provider, subject)` link, never on login or email.

  **Derivation (ADR-20).** Scopes come from Project membership (`Swarm.Projects.effective_scopes/1`
  — a user, or a group the user is in, is a member of a Project that owns Sources), never from a
  group grant; the fixed groups `wheel` / `admins` / `staff` carry ROLES only. Capabilities come
  from the group-conferred `admin` role plus, for a live `Swarm.Elevation` bound to the actor's
  session, the `superadmin` set. Default-deny throughout: no membership ⇒ exactly `["public"]`;
  no role ⇒ no capability. Credentials and IdP secrets never live here.
  """

  alias Swarm.{Elevation, Projects, Repo}

  @wheel "wheel"
  @admins "admins"
  @staff "staff"
  @fixed_groups [{@wheel, "Wheel"}, {@admins, "Admins"}, {@staff, "Staff"}]
  @fixed_group_ids Enum.map(@fixed_groups, &elem(&1, 0))

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
          external: boolean(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_login_at: DateTime.t() | nil
        }
  @typedoc """
  Who is acting: a bare uuid (never elevated), or `{uuid, sid}` / `%{uuid: _, sid: _}` from a
  resolved assertion — the session an elevation may be bound to.
  """
  @type actor_ref ::
          String.t() | {String.t(), String.t() | nil} | %{required(:uuid) => String.t()}

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

  # ── the fixed groups (ADR-20 D7) ───────────────────────────────────────

  @doc "The fixed group ids: `wheel`, `admins`, `staff` (ADR-20 — no arbitrary group lifecycle)."
  @spec fixed_groups() :: [String.t()]
  def fixed_groups, do: @fixed_group_ids

  @doc "The Wheel group id (local-only break-glass cohort; members may elevate)."
  @spec wheel() :: String.t()
  def wheel, do: @wheel

  @doc "The Admins group id (confers the `admin` role)."
  @spec admins() :: String.t()
  def admins, do: @admins

  @doc "The Staff group id (the default internal cohort; confers no role)."
  @spec staff() :: String.t()
  def staff, do: @staff

  @doc """
  Ensure the three fixed groups and the `admins → admin` role binding exist (idempotent). The
  migration seeds them; this is the fresh-boot / test belt so a JIT provision can never find
  its default cohort missing.
  """
  @spec ensure_fixed_groups() :: :ok
  def ensure_fixed_groups do
    for {id, name} <- @fixed_groups do
      Repo.query!(
        """
        INSERT INTO access_group (id, source, name) VALUES ($1, 'local', $2)
        ON CONFLICT (id) DO NOTHING
        """,
        [id, name]
      )
    end

    Repo.query!(
      "INSERT INTO group_role (group_id, role) VALUES ($1, 'admin') ON CONFLICT (group_id, role) DO NOTHING",
      [@admins]
    )

    :ok
  end

  @doc """
  The default internal cohort every NON-external account joins at provisioning
  (`config :swarm, :identity, default_cohort` — `"staff"`; `nil`/`""` disables). Guests
  (`external = true`) never join it (ADR-20 Guests).
  """
  @spec default_cohort_group() :: String.t() | nil
  def default_cohort_group do
    case Application.get_env(:swarm, :identity, [])[:default_cohort] do
      g when is_binary(g) and g != "" -> g
      _ -> nil
    end
  end

  # ── JIT provisioning ──────────────────────────────────────────────────

  @doc """
  Find-or-create the user for a set of *verified* claims, idempotently, matching
  on `(provider, subject)`. Updates the mutable attributes (login, names),
  promotes `invited → active` on first authenticated login, touches
  `last_login_at`, reconciles emails + IdP group memberships to the claim set (a group
  dropped from the claims is revoked — default-deny) and joins the default cohort
  (`staff`) unless the account is a guest. Returns the user.
  """
  @spec upsert_from_claims(claims()) :: {:ok, user()}
  def upsert_from_claims(claims) do
    {:ok, id} =
      Repo.transaction(fn ->
        user_id = find_or_create_user(claims)
        sync_emails(user_id, Map.get(claims, :emails, []))
        sync_groups(user_id, Map.get(claims, :provider), Map.get(claims, :groups, []))
        ensure_default_cohort(user_id)
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

  @spec sync_groups(String.t(), String.t() | nil, [String.t()] | nil) :: :ok
  defp sync_groups(user_id, provider, incoming) do
    incoming = incoming || []

    mapped_groups =
      Repo.query!(
        """
        SELECT DISTINCT our_group_id
          FROM sso_group_map
         WHERE provider = $1
           AND incoming_group = ANY($2::text[])
           AND our_group_id <> $3
         ORDER BY our_group_id
        """,
        [provider, incoming, @wheel]
      ).rows
      |> List.flatten()

    Enum.each(mapped_groups, fn group_id ->
      Repo.query!(
        """
        INSERT INTO user_group (user_id, group_id, source)
        VALUES ($1, $2, 'idp')
        ON CONFLICT (user_id, group_id) DO NOTHING
        """,
        [cast_to_uuid(user_id), group_id]
      )
    end)

    # Revoke IdP memberships no longer asserted through the kernel-owned map.
    Repo.query!(
      """
      DELETE FROM user_group
       WHERE user_id = $1
         AND source = 'idp'
         AND NOT (group_id = ANY($2::text[]))
      """,
      [cast_to_uuid(user_id), mapped_groups]
    )

    :ok
  end

  # The default internal cohort (ADR-20 "Staff is the default internal cohort"): a
  # non-guest joins it at provisioning; the membership is `source = 'default'` so an IdP
  # group re-sync never revokes it. A guest never joins.
  @spec ensure_default_cohort(String.t()) :: :ok
  defp ensure_default_cohort(user_id) do
    with group when is_binary(group) <- default_cohort_group(),
         false <- external?(user_id) do
      ensure_fixed_groups()

      Repo.query!(
        """
        INSERT INTO user_group (user_id, group_id, source) VALUES ($1, $2, 'default')
        ON CONFLICT (user_id, group_id) DO NOTHING
        """,
        [cast_to_uuid(user_id), group]
      )

      :ok
    else
      _ -> :ok
    end
  end

  # ── Wheel bootstrap (the root/uid-0 mechanism, ADR-20) ─────────────────

  @doc """
  Idempotently seed a local Wheel member: an active local user with the given (vanity)
  UUIDv7 `id` and `login`, a member of `wheel` (may elevate) AND `admins` (daily admin
  without elevating). No standing superadmin is conferred — that exists only as an
  elevation. The concrete id + login are deployment config (hive seeds them at bootstrap).
  """
  @spec seed_wheel(%{id: String.t(), login: String.t()}) :: {:ok, user()}
  def seed_wheel(%{id: id, login: login}) do
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

        ensure_fixed_groups()

        for group <- [@wheel, @admins] do
          Repo.query!(
            "INSERT INTO user_group (user_id, group_id, source) VALUES ($1, $2, 'local') ON CONFLICT (user_id, group_id) DO NOTHING",
            [cast_to_uuid(id), group]
          )
        end

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

        ensure_default_cohort(id)
      end)

    {:ok, get_user(id)}
  end

  # ── Mutations (the audited, cap-gated callers live in Swarm.Admin) ─────

  @doc """
  Add a user to one of the fixed groups (idempotent). `wheel` takes local-only users
  (no external IdP link — ADR-19 D4/D8 carried into ADR-20) — the deepest belt behind
  the `Swarm.Admin` gate.
  """
  @spec add_to_group(String.t(), String.t()) ::
          :ok | {:error, :unknown_group | :wheel_local_only}
  def add_to_group(user_id, group_id) do
    cond do
      group_id not in @fixed_group_ids or not group_exists?(group_id) ->
        {:error, :unknown_group}

      group_id == @wheel and not local_only?(user_id) ->
        {:error, :wheel_local_only}

      true ->
        Repo.query!(
          """
          INSERT INTO user_group (user_id, group_id, source) VALUES ($1, $2, 'local')
          ON CONFLICT (user_id, group_id) DO NOTHING
          """,
          [cast_to_uuid(user_id), group_id]
        )

        :ok
    end
  end

  @doc """
  Remove a user from a group. Leaving `wheel` revokes the user's live elevations in the
  same transaction (an elevation cannot outlive the eligibility that granted it).
  """
  @spec remove_from_group(String.t(), String.t()) :: :ok
  def remove_from_group(user_id, group_id) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM user_group WHERE user_id = $1 AND group_id = $2", [
          cast_to_uuid(user_id),
          group_id
        ])

        if group_id == @wheel, do: Elevation.revoke_all(user_id)
      end)

    :ok
  end

  @doc "Whether a group exists (the fixed set, plus any group row the store still holds)."
  @spec group_exists?(String.t()) :: boolean()
  def group_exists?(id) when is_binary(id) do
    case Repo.query!("SELECT 1 FROM access_group WHERE id = $1", [id]) do
      %{rows: [[1]]} -> true
      %{rows: []} -> false
    end
  end

  def group_exists?(_), do: false

  @doc "Whether the user is a member of `wheel`."
  @spec wheel_member?(String.t()) :: boolean()
  def wheel_member?(user_id), do: @wheel in groups_for(user_id)

  @doc """
  Active, local-only members of `wheel` — the break-glass cohort that must never become
  empty (the bootstrap invariant, `Swarm.Admin` refuses the op that would empty it).
  """
  @spec active_local_wheel_count() :: non_neg_integer()
  def active_local_wheel_count do
    [[n]] =
      Repo.query!(
        """
        SELECT count(*)::int
          FROM app_user u
          JOIN user_group ug ON ug.user_id = u.id AND ug.group_id = $1
         WHERE u.status = 'active'
           AND EXISTS (SELECT 1 FROM identity_link l WHERE l.user_id = u.id AND l.provider = 'local')
           AND NOT EXISTS (SELECT 1 FROM identity_link l WHERE l.user_id = u.id AND l.provider <> 'local')
        """,
        [@wheel]
      ).rows

    n
  end

  @grantable_group_roles ~w(admin)

  @doc """
  Bind a role to a group. Only `admin` is bindable (ADR-20 D9: `superadmin` is never a
  standing role — it exists only as an elevation).
  """
  @spec set_group_role(String.t(), String.t()) :: :ok | {:error, :invalid_role | :unknown_group}
  def set_group_role(id, role) do
    cond do
      role not in @grantable_group_roles ->
        {:error, :invalid_role}

      not group_exists?(id) ->
        {:error, :unknown_group}

      true ->
        Repo.query!(
          """
          INSERT INTO group_role (group_id, role)
          VALUES ($1, $2)
          ON CONFLICT (group_id, role) DO NOTHING
          """,
          [id, role]
        )

        :ok
    end
  end

  @doc "Remove one group-conferred role."
  @spec clear_group_role(String.t(), String.t()) :: :ok
  def clear_group_role(id, role) do
    Repo.query!("DELETE FROM group_role WHERE group_id = $1 AND role = $2", [id, role])
    :ok
  end

  @doc "Count current members of a group."
  @spec group_member_count(String.t()) :: non_neg_integer()
  def group_member_count(id) do
    [[count]] =
      Repo.query!("SELECT count(*)::int FROM user_group WHERE group_id = $1", [id]).rows

    count
  end

  @doc """
  Map an incoming SSO group claim to a kernel-owned access group. The target must exist and
  must not be `wheel` (local-only, never IdP-reachable); unmapped incoming groups grant nothing.
  """
  @spec put_sso_group_map(String.t(), String.t(), String.t()) ::
          :ok | {:error, :unknown_group | :wheel_not_mappable}
  def put_sso_group_map(provider, incoming, our_group_id) do
    cond do
      our_group_id == @wheel ->
        {:error, :wheel_not_mappable}

      our_group_id not in @fixed_group_ids or not group_exists?(our_group_id) ->
        {:error, :unknown_group}

      true ->
        Repo.query!(
          """
          INSERT INTO sso_group_map (provider, incoming_group, our_group_id)
          VALUES ($1, $2, $3)
          ON CONFLICT (provider, incoming_group) DO UPDATE
            SET our_group_id = EXCLUDED.our_group_id
          """,
          [provider, incoming, our_group_id]
        )

        :ok
    end
  end

  @doc "Delete an SSO group mapping if present."
  @spec delete_sso_group_map(String.t(), String.t()) :: :ok
  def delete_sso_group_map(provider, incoming) do
    Repo.query!(
      "DELETE FROM sso_group_map WHERE provider = $1 AND incoming_group = $2",
      [provider, incoming]
    )

    :ok
  end

  @doc "List SSO group mappings ordered by provider and incoming group."
  @spec list_sso_group_map() :: [
          %{provider: String.t(), incoming_group: String.t(), our_group_id: String.t()}
        ]
  def list_sso_group_map do
    Repo.query!("""
    SELECT provider, incoming_group, our_group_id
      FROM sso_group_map
     ORDER BY provider, incoming_group
    """).rows
    |> Enum.map(fn [provider, incoming_group, our_group_id] ->
      %{provider: provider, incoming_group: incoming_group, our_group_id: our_group_id}
    end)
  end

  @doc """
  Create an invited local user (no credential — the channel sets the password) with
  a local `identity_link` so local login resolves. `attrs`: `:login` (required),
  `:first_name`, `:last_name`, `:nickname`, `:external` (a GUEST — never joins the default
  cohort, receives no internal visibility unless explicitly added to a Project).
  """
  @spec invite_user(map()) :: {:ok, user()}
  def invite_user(attrs) do
    id = uuid7()
    login = Map.fetch!(attrs, :login)
    external = Map.get(attrs, :external, false) == true

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO app_user (id, login, first_name, last_name, nickname, status, external)
          VALUES ($1, $2, $3, $4, $5, 'invited', $6)
          """,
          [
            cast_to_uuid(id),
            login,
            Map.get(attrs, :first_name),
            Map.get(attrs, :last_name),
            Map.get(attrs, :nickname),
            external
          ]
        )

        Repo.query!(
          "INSERT INTO identity_link (user_id, provider, subject) VALUES ($1, 'local', $2)",
          [cast_to_uuid(id), login]
        )

        ensure_default_cohort(id)
      end)

    {:ok, get_user(id)}
  end

  @doc """
  Deactivate an account: `status = disabled`; every authority source dies with it — group
  memberships, direct Project memberships and live elevations (login is blocked by
  `Swarm.Actor.resolve`). Learned content is retained (D11).
  """
  @spec deactivate_user(String.t()) :: :ok
  def deactivate_user(user_id) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          "UPDATE app_user SET status = 'disabled', updated_at = now() WHERE id = $1",
          [cast_to_uuid(user_id)]
        )

        kill_authority(user_id)
      end)

    :ok
  end

  @doc """
  Delete an account: `status = deleted` + every login path removed (group + Project
  memberships, elevations, identity links; credential is channel-side). The `app_user` row
  PERSISTS (FK + audit integrity) and learned/derived content persists — a self-hosted
  instance, not a right-to-erasure (D11).
  """
  @spec delete_user(String.t()) :: :ok
  def delete_user(user_id) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          "UPDATE app_user SET status = 'deleted', updated_at = now() WHERE id = $1",
          [cast_to_uuid(user_id)]
        )

        kill_authority(user_id)
        Repo.query!("DELETE FROM identity_link WHERE user_id = $1", [cast_to_uuid(user_id)])
      end)

    :ok
  end

  @spec kill_authority(String.t()) :: :ok
  defp kill_authority(user_id) do
    Elevation.revoke_all(user_id)
    Repo.query!("DELETE FROM user_group WHERE user_id = $1", [cast_to_uuid(user_id)])

    Repo.query!("DELETE FROM project_membership WHERE user_id = $1", [cast_to_uuid(user_id)])

    :ok
  end

  # ── Reads (derivation happens here, never from a channel field) ────────

  @user_cols "id, login, first_name, last_name, nickname, status, external, created_at, updated_at, last_login_at"

  @doc "Fetch a user by uuid, or `nil`."
  @spec get_user(String.t()) :: user() | nil
  def get_user(id) do
    with {:ok, bin} <- Ecto.UUID.dump(id),
         %{rows: [row]} <- Repo.query!("SELECT #{@user_cols} FROM app_user WHERE id = $1", [bin]) do
      to_user(row)
    else
      _ -> nil
    end
  end

  @doc "Fetch a user by `login`, or `nil`."
  @spec by_login(String.t()) :: user() | nil
  def by_login(login) do
    case Repo.query!("SELECT #{@user_cols} FROM app_user WHERE login = $1", [login]) do
      %{rows: [row]} -> to_user(row)
      %{rows: []} -> nil
    end
  end

  @doc "Whether the account is a guest (`external = true`)."
  @spec external?(String.t()) :: boolean()
  def external?(user_id) do
    case get_user(user_id) do
      %{external: e} -> e
      nil -> false
    end
  end

  # ListUsers is bounded BY CONTRACT (council: gemini) — enforced in the SQL, not
  # in memory; the wire `limit` is clamped into (0, @list_users_cap].
  @list_users_cap 500

  @doc """
  The user roster for an admin console: each row aggregates roles (group-conferred),
  groups and identity-link providers. Tombstones (status=deleted) are excluded unless
  `include_deleted: true`. Supports literal case-insensitive substring search over
  names/login and offset paging. Deterministic order (login, id), SQL-bounded. Returns
  `{rows, total}` where `total` is the pre-page count.
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
        SELECT u.id, u.login, u.first_name, u.last_name, u.nickname, u.status, u.external, u.last_login_at,
               coalesce((
                 SELECT array_agg(DISTINCT gr.role ORDER BY gr.role) FROM group_role gr
                   JOIN user_group ug ON ug.group_id = gr.group_id
                  WHERE ug.user_id = u.id
               ), '{}'),
               coalesce(array_agg(DISTINCT g.group_id) FILTER (WHERE g.group_id IS NOT NULL), '{}'),
               coalesce(array_agg(DISTINCT l.provider) FILTER (WHERE l.provider IS NOT NULL), '{}'),
               count(*) OVER()
          FROM app_user u
          LEFT JOIN user_group g ON g.user_id = u.id
          LEFT JOIN identity_link l ON l.user_id = u.id
         WHERE ($1 OR u.status <> 'deleted')
           AND ($2 OR u.login ILIKE $3 ESCAPE '\\'
                   OR u.first_name ILIKE $3 ESCAPE '\\'
                   OR u.last_name ILIKE $3 ESCAPE '\\'
                   OR u.nickname ILIKE $3 ESCAPE '\\')
         GROUP BY u.id, u.login, u.first_name, u.last_name, u.nickname, u.status, u.external, u.last_login_at
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
                          external,
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
          external: external,
          last_login_at: last_login,
          roles: roles,
          groups: groups,
          providers: providers
        }
      end)

    total =
      case rows do
        [row | _] -> List.last(row)
        [] -> 0
      end

    {users, total}
  end

  @doc """
  Read-only group registry for the admin console: the fixed groups (plus any group row the
  store still holds) with member counts and the roles they confer. Groups grant NO scopes
  (ADR-20 D3) — there is no scope column any more.
  """
  @spec list_groups() :: [
          %{
            id: String.t(),
            name: String.t() | nil,
            description: String.t() | nil,
            member_count: non_neg_integer(),
            granted_roles: [String.t()]
          }
        ]
  def list_groups do
    Repo.query!(
      """
      SELECT ag.id, ag.name, ag.description,
             (SELECT count(*)::int FROM user_group ug WHERE ug.group_id = ag.id),
             coalesce((SELECT array_agg(DISTINCT role ORDER BY role) FROM group_role gr WHERE gr.group_id = ag.id), '{}'::text[])
        FROM access_group ag
       ORDER BY ag.id
      """,
      []
    ).rows
    |> Enum.map(fn [id, name, description, member_count, granted_roles] ->
      %{
        id: id,
        name: name,
        description: description,
        member_count: member_count,
        granted_roles: granted_roles
      }
    end)
  end

  @doc """
  One group with its view (as in `list_groups/0`) plus its member list
  (login + providers + status, tombstones excluded, login-ordered). `nil` when the
  group is unknown.
  """
  @spec get_group(String.t()) :: %{group: map(), members: [map()]} | nil
  def get_group(id) do
    case Enum.find(list_groups(), &(&1.id == id)) do
      nil -> nil
      view -> %{group: view, members: group_members(id)}
    end
  end

  @spec group_members(String.t()) :: [map()]
  defp group_members(id) do
    Repo.query!(
      """
      SELECT u.id::text, u.login, u.status,
             coalesce(
               array_agg(DISTINCT l.provider) FILTER (WHERE l.provider IS NOT NULL),
               '{}'::text[]
             )
        FROM user_group ug
        JOIN app_user u ON u.id = ug.user_id
        LEFT JOIN identity_link l ON l.user_id = u.id
       WHERE ug.group_id = $1 AND u.status <> 'deleted'
       GROUP BY u.id, u.login, u.status
       ORDER BY u.login
      """,
      [id]
    ).rows
    |> Enum.map(fn [uid, login, status, providers] ->
      %{user_id: uid, login: login, status: status, providers: providers}
    end)
  end

  @known_roles ~w(user admin superadmin)

  @doc """
  Read-only role list for the admin console. `user` is implicit (holder count 0); `admin`
  holders are the members of role-bearing groups; `superadmin` holders are the users with a
  LIVE elevation right now (never a standing set).
  """
  @spec list_roles() :: [
          %{name: String.t(), capabilities: [String.t()], holder_count: non_neg_integer()}
        ]
  def list_roles do
    [[admins]] =
      Repo.query!("""
      SELECT count(DISTINCT ug.user_id)::int
        FROM group_role gr
        JOIN user_group ug ON ug.group_id = gr.group_id
       WHERE gr.role = 'admin'
      """).rows

    counts = %{"admin" => admins, "superadmin" => Elevation.active_holder_count()}

    Enum.map(@known_roles, fn role ->
      %{
        name: role,
        capabilities: role |> caps_for_role() |> Enum.uniq() |> Enum.sort(),
        holder_count: Map.get(counts, role, 0)
      }
    end)
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
  Full admin-visible view for one non-deleted user, including emails and the Projects the
  user can see (membership or public). Returns `nil` for an unknown or tombstoned user.
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
          external: user.external,
          last_login_at: user.last_login_at,
          roles: roles_for(user.id),
          groups: groups_for(user.id),
          providers: providers_for(user.id),
          emails: user.id |> emails_for() |> Enum.map(& &1.email),
          projects: user.id |> Projects.list_projects_for() |> Enum.map(& &1.id)
        }
    end
  end

  @doc """
  The scopes a user derives: the **authenticated baseline `public`** plus the source scopes
  of the Projects they are a member of — directly or through a group — plus every `public`
  Project's Sources (`Swarm.Projects.effective_scopes/1`). No membership ⇒ exactly
  `["public"]`. `private` never enters (the per-user chat-privacy scope is not derivable —
  person-scope-leak-guard belt).
  """
  @spec scopes_for(String.t()) :: [String.t()]
  def scopes_for(id) do
    (["public"] ++ Projects.effective_scopes(id))
    |> Enum.reject(&(&1 == "private"))
    |> Enum.uniq()
  end

  @doc """
  The roles an actor holds: those conferred by their groups (`group_role` via `user_group`)
  plus `superadmin` iff a live elevation is bound to the actor's session (ADR-20 D9 — never a
  standing role). Default-deny — `[]` when none.
  """
  @spec roles_for(actor_ref()) :: [String.t()]
  def roles_for(actor) do
    {uuid, sid} = actor_ref(actor)

    group_roles =
      Repo.query!(
        """
        SELECT DISTINCT gr.role
          FROM group_role gr
          JOIN user_group ug ON ug.group_id = gr.group_id
         WHERE ug.user_id = $1
         ORDER BY gr.role
        """,
        [cast_to_uuid(uuid)]
      ).rows
      |> List.flatten()

    if Elevation.active?(uuid, sid),
      do: Enum.sort(Enum.uniq(group_roles ++ ["superadmin"])),
      else: group_roles
  end

  # Role → capability policy (ADR-16 D7, ADR-20 §5/§6). superadmin ⊃ admin, and alone holds
  # the elevation-only capabilities (break-glass read, wheel, roles, auth config, publicness).
  @admin_caps ~w(manage_access invite_users manage_users manage_projects)
  @superadmin_caps @admin_caps ++
                     ~w(read_any_conversation manage_wheel manage_roles manage_auth manage_publicness)

  @doc "The capabilities the `admin` role confers."
  @spec admin_caps() :: [String.t()]
  def admin_caps, do: @admin_caps

  @doc "The capabilities an ACTIVE elevation (`superadmin`) confers."
  @spec superadmin_caps() :: [String.t()]
  def superadmin_caps, do: @superadmin_caps

  @spec caps_for_role(String.t()) :: [String.t()]
  defp caps_for_role("superadmin"), do: @superadmin_caps
  defp caps_for_role("admin"), do: @admin_caps
  defp caps_for_role(_), do: []

  @doc """
  The capabilities an actor holds, **derived** from `roles_for/1` at every call (default-deny —
  `[]` when no role). An elevated capability disappears the moment the elevation does.
  """
  @spec caps_for(actor_ref()) :: [String.t()]
  def caps_for(actor) do
    actor
    |> roles_for()
    |> Enum.flat_map(&caps_for_role/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The uuid behind an actor ref."
  @spec actor_uuid(actor_ref()) :: String.t()
  def actor_uuid(actor), do: actor |> actor_ref() |> elem(0)

  @doc "Normalize an actor ref to `{uuid, sid | nil}`."
  @spec actor_ref(actor_ref()) :: {String.t(), String.t() | nil}
  def actor_ref({uuid, sid}) when is_binary(uuid), do: {uuid, sid}
  def actor_ref(%{uuid: uuid} = a) when is_binary(uuid), do: {uuid, Map.get(a, :sid)}
  def actor_ref(uuid) when is_binary(uuid), do: {uuid, nil}

  @doc """
  True iff the user has a `local` identity_link and NO non-local link: the `wheel` group takes
  local-provider users only (a local break-glass account that links an SSO subject would hand
  the IdP an indirect superadmin path).
  """
  @spec local_only?(String.t()) :: boolean()
  def local_only?(user_id) do
    providers =
      Repo.query!(
        "SELECT DISTINCT provider FROM identity_link WHERE user_id = $1",
        [cast_to_uuid(user_id)]
      ).rows
      |> List.flatten()

    "local" in providers and Enum.all?(providers, &(&1 == "local"))
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

  @spec to_user([term()]) :: user()
  defp to_user([
         id,
         login,
         first_name,
         last_name,
         nickname,
         status,
         external,
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
      external: external,
      created_at: created_at,
      updated_at: updated_at,
      last_login_at: last_login_at
    }
  end
end
