defmodule Swarm.Elevation do
  @moduledoc """
  Time-boxed `superadmin` elevation for local Wheel members (workspace ADR-20 D7/D9/D11).

  There is NO standing superadmin. A member of the `wheel` group (local-only — no external IdP
  link) who holds a verified actor assertion may REQUEST an elevation with a reason and a
  fresh **re-authentication proof**; the kernel writes the audit row and the elevation row in
  ONE transaction (the audit is durable at the instant the capability exists — never after),
  and `Swarm.Identity.caps_for/1` includes the superadmin capabilities only while
  `active?/2` holds. Nothing caches the capability: expiry, revocation, deactivation, removal
  from `wheel` or a new external IdP link end it on the very next call.

  ## The re-authentication proof (channel-signed, kernel-verified)

  The channel owns passwords (ADR-16 A1), so the kernel cannot check one — it checks the
  cryptographic RECORD that the channel just did: an HS256 token with the shared actor secret
  and the distinct audience `swarm.reauth.v1`:

      {"aud":"swarm.reauth.v1","sub":<local login>,"provider":"local","sid":<session>,
       "jti":<one-time id>,"auth_time":<unix s of the password check>,"iat":…,"exp":…}

  Checks: signature + audience (`Swarm.Actor.verify/2`), `exp - iat` ≤ 60 s, `provider ==
  "local"`, the subject resolves to the SAME user as the actor assertion, the `sid` equals the
  assertion's session, `auth_time` is at most `reauth_max_age_s` old (default 120 s), and the
  `jti` has never been consumed (UNIQUE — a replayed proof cannot re-elevate; council gemini).

  ## Binding

  An elevation is bound to the SESSION (`sid`) that requested it — another session of the
  same user is not elevated (council codex: sudo is per shell). Data break-glass stays
  per-operation (`Swarm.Conversations.admin_read/3`): elevation is not an ambient read path.
  """

  alias Swarm.{Actor, Audit, Identity, Repo}

  @wheel "wheel"
  @default_ttl_s 900
  @min_ttl_s 60
  @max_ttl_s 3600
  @reauth_max_age_s 120
  @reauth_max_ttl_s 60

  @type actor :: %{required(:uuid) => String.t(), required(:sid) => String.t() | nil}
  @type elevation :: %{
          id: String.t(),
          user_id: String.t(),
          sid: String.t(),
          reason: String.t(),
          created_at: term(),
          expires_at: term(),
          revoked_at: term() | nil
        }
  @type reason ::
          :reason_required
          | :no_session
          | :not_wheel
          | :not_local
          | :inactive
          | :reauth_invalid
          | :reauth_stale
          | :reauth_subject_mismatch
          | :reauth_session_mismatch
          | :reauth_replayed

  @doc "The configured default elevation TTL (seconds)."
  @spec default_ttl_s() :: pos_integer()
  def default_ttl_s,
    do: Application.get_env(:swarm, :elevation, [])[:default_ttl_s] || @default_ttl_s

  @doc "The configured maximum elevation TTL (seconds)."
  @spec max_ttl_s() :: pos_integer()
  def max_ttl_s, do: Application.get_env(:swarm, :elevation, [])[:max_ttl_s] || @max_ttl_s

  @doc """
  Request an elevation for the verified `actor` (`%{uuid, sid}` from `Swarm.Actor.resolve/2`).
  `opts`: `:ttl_s` (clamped to `[60, max_ttl_s]`), `:now` (test clock), plus `Swarm.Actor.verify/2`
  options for the proof. Every refusal is audited (`elevate` / `denied` / reason) — privilege
  probing is visible.
  """
  @spec request(actor(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, elevation()} | {:error, reason()}
  def request(%{uuid: uuid} = actor, reason, reauth_token, opts \\ []) do
    sid = Map.get(actor, :sid)

    with {:ok, reason} <- non_blank(reason, :reason_required),
         {:ok, sid} <- non_blank(sid, :no_session),
         :ok <- check_eligible(uuid),
         {:ok, jti} <- check_reauth(uuid, sid, reauth_token, opts) do
      grant(uuid, sid, reason, jti, opts)
    else
      {:error, why} = err ->
        audit(uuid, "elevate", "denied", reason: to_string(why))
        err
    end
  end

  @doc """
  End (revoke) an elevation. With `elevation_id: nil` the actor's own live elevation for this
  session; a specific id may be revoked by its holder or by an elevated Wheel member.
  """
  @spec end_elevation(actor(), String.t() | nil) :: :ok | :not_found | :not_authorized
  def end_elevation(%{uuid: uuid} = actor, elevation_id \\ nil) do
    sid = Map.get(actor, :sid)
    target = if is_nil(elevation_id), do: active(uuid, sid), else: fetch(elevation_id)
    revoke_target(uuid, sid, target)
  end

  defp revoke_target(_uuid, _sid, nil), do: :not_found
  defp revoke_target(uuid, _sid, %{user_id: uuid} = e), do: revoke(e.id, uuid)

  defp revoke_target(uuid, sid, e) do
    if active?(uuid, sid) do
      revoke(e.id, uuid)
    else
      audit(uuid, "end_elevation", "denied", target_user_id: e.user_id)
      :not_authorized
    end
  end

  @doc """
  Revoke every live elevation of `user_id` (deactivate / delete / removal from wheel — the
  transactional belt behind the live re-check in `active/2`). Returns the count revoked.
  """
  @spec revoke_all(String.t()) :: non_neg_integer()
  def revoke_all(user_id) do
    %{num_rows: n} =
      Repo.query!(
        "UPDATE elevation SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()",
        [dump(user_id)]
      )

    n
  end

  @doc """
  The live elevation for `(user_id, sid)`, or `nil`. Live = not revoked, not expired, AND —
  re-checked here at every resolution — the user is still `active`, still in `wheel` and still
  local-only. `sid` `nil`/blank ⇒ never elevated.
  """
  @spec active(String.t(), String.t() | nil) :: elevation() | nil
  def active(_user_id, sid) when sid in [nil, ""], do: nil

  def active(user_id, sid) do
    case Repo.query!(
           """
           SELECT #{cols("e")}
             FROM elevation e
             JOIN app_user u ON u.id = e.user_id
            WHERE e.user_id = $1 AND e.sid = $2
              AND e.revoked_at IS NULL AND e.expires_at > now()
              AND u.status = 'active'
              AND EXISTS (SELECT 1 FROM user_group ug WHERE ug.user_id = u.id AND ug.group_id = $3)
              AND EXISTS (SELECT 1 FROM identity_link l WHERE l.user_id = u.id AND l.provider = 'local')
              AND NOT EXISTS (SELECT 1 FROM identity_link l WHERE l.user_id = u.id AND l.provider <> 'local')
            ORDER BY e.expires_at DESC
            LIMIT 1
           """,
           [dump(user_id), sid, @wheel]
         ) do
      %{rows: [row]} -> to_elevation(row)
      %{rows: []} -> nil
    end
  end

  @doc "True iff `active/2` returns a live elevation."
  @spec active?(String.t(), String.t() | nil) :: boolean()
  def active?(user_id, sid), do: not is_nil(active(user_id, sid))

  @doc "Distinct users holding a live (time-valid, unrevoked) elevation — the roles view."
  @spec active_holder_count() :: non_neg_integer()
  def active_holder_count do
    [[n]] =
      Repo.query!(
        "SELECT count(DISTINCT user_id)::int FROM elevation WHERE revoked_at IS NULL AND expires_at > now()"
      ).rows

    n
  end

  @doc "Fetch an elevation row by id (any state), or `nil`."
  @spec fetch(String.t()) :: elevation() | nil
  def fetch(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %{rows: [row]} <-
           Repo.query!("SELECT #{cols("e")} FROM elevation e WHERE e.id = $1", [dump(id)]) do
      to_elevation(row)
    else
      _ -> nil
    end
  end

  # ── checks ─────────────────────────────────────────────────────────────────

  defp non_blank(v, _why) when is_binary(v) and v != "" do
    if String.trim(v) == "", do: {:error, :reason_required}, else: {:ok, v}
  end

  defp non_blank(_v, why), do: {:error, why}

  # Eligibility is re-derived from the store, never taken from the caller.
  defp check_eligible(uuid) do
    cond do
      match?(%{status: s} when s != "active", Identity.get_user(uuid)) -> {:error, :inactive}
      is_nil(Identity.get_user(uuid)) -> {:error, :inactive}
      @wheel not in Identity.groups_for(uuid) -> {:error, :not_wheel}
      not Identity.local_only?(uuid) -> {:error, :not_local}
      true -> :ok
    end
  end

  defp check_reauth(uuid, sid, token, opts) when is_binary(token) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    max_age = Application.get_env(:swarm, :elevation, [])[:reauth_max_age_s] || @reauth_max_age_s

    with {:ok, claims} <- verify_proof(token, opts),
         :ok <- same_subject(claims, uuid),
         :ok <- same_session(claims, sid),
         :ok <- fresh(claims, now, max_age),
         {:ok, jti} <- non_blank(claims["jti"], :reauth_invalid) do
      if jti_used?(jti), do: {:error, :reauth_replayed}, else: {:ok, jti}
    end
  end

  defp check_reauth(_uuid, _sid, _token, _opts), do: {:error, :reauth_invalid}

  defp verify_proof(token, opts) do
    case Actor.verify(token, Keyword.put(opts, :audience, Actor.reauth_audience())) do
      {:ok, %{"iat" => iat, "exp" => exp} = claims}
      when is_integer(iat) and is_integer(exp) and exp - iat <= @reauth_max_ttl_s ->
        {:ok, claims}

      {:ok, _} ->
        {:error, :reauth_invalid}

      {:error, _} ->
        {:error, :reauth_invalid}
    end
  end

  defp same_subject(%{"provider" => "local", "sub" => sub}, uuid) when is_binary(sub) do
    case Identity.user_by_link("local", sub) do
      %{id: ^uuid} -> :ok
      _ -> {:error, :reauth_subject_mismatch}
    end
  end

  defp same_subject(_claims, _uuid), do: {:error, :reauth_subject_mismatch}

  defp same_session(%{"sid" => sid}, sid) when is_binary(sid) and sid != "", do: :ok
  defp same_session(_claims, _sid), do: {:error, :reauth_session_mismatch}

  defp fresh(%{"auth_time" => t}, now, max_age) when is_integer(t) do
    if t <= now + 30 and now - t <= max_age, do: :ok, else: {:error, :reauth_stale}
  end

  defp fresh(_claims, _now, _max_age), do: {:error, :reauth_invalid}

  defp jti_used?(jti) do
    match?(%{rows: [[1]]}, Repo.query!("SELECT 1 FROM elevation WHERE reauth_jti = $1", [jti]))
  end

  # ── grant (audit FIRST, same transaction) ──────────────────────────────────

  defp grant(uuid, sid, reason, jti, opts) do
    ttl = opts |> Keyword.get(:ttl_s, default_ttl_s()) |> clamp_ttl()
    id = Identity.uuid7()

    result =
      Repo.transaction(fn ->
        expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

        Audit.record(%{
          actor_id: uuid,
          action: "elevate",
          decision: "allowed",
          reason: reason,
          data_returned: false,
          detail: %{
            "elevation_id" => id,
            "sid" => sid,
            "ttl_s" => ttl,
            "expires_at" => DateTime.to_iso8601(expires_at)
          }
        })

        Repo.query!(
          """
          INSERT INTO elevation (id, user_id, reason, sid, reauth_jti, expires_at)
          VALUES ($1, $2, $3, $4, $5, $6)
          """,
          [dump(id), dump(uuid), reason, sid, jti, expires_at]
        )

        fetch(id)
      end)

    case result do
      {:ok, %{} = e} -> {:ok, e}
      {:error, _} -> {:error, :reauth_replayed}
    end
  rescue
    # A lost race on the one-time jti (UNIQUE) is a replay, not a 500.
    e in Postgrex.Error ->
      if e.postgres && e.postgres.code == :unique_violation,
        do: {:error, :reauth_replayed},
        else: reraise(e, __STACKTRACE__)
  end

  defp clamp_ttl(ttl) when is_integer(ttl), do: ttl |> max(@min_ttl_s) |> min(max_ttl_s())
  defp clamp_ttl(_), do: default_ttl_s()

  defp revoke(id, actor_id) do
    Repo.query!("UPDATE elevation SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL", [
      dump(id)
    ])

    audit(actor_id, "end_elevation", "allowed", detail: %{"elevation_id" => id})
    :ok
  end

  defp audit(actor_id, action, decision, opts) do
    Audit.record(%{
      actor_id: actor_id,
      action: action,
      decision: decision,
      reason: Keyword.get(opts, :reason),
      target_user_id: Keyword.get(opts, :target_user_id),
      detail: Keyword.get(opts, :detail),
      data_returned: false
    })

    :ok
  end

  # ── rows ───────────────────────────────────────────────────────────────────

  defp cols(p),
    do:
      "#{p}.id::text, #{p}.user_id::text, #{p}.sid, #{p}.reason, #{p}.created_at, #{p}.expires_at, #{p}.revoked_at"

  defp to_elevation([id, user_id, sid, reason, created_at, expires_at, revoked_at]) do
    %{
      id: id,
      user_id: user_id,
      sid: sid,
      reason: reason,
      created_at: created_at,
      expires_at: expires_at,
      revoked_at: revoked_at
    }
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
