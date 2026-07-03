defmodule Swarm.Actor do
  @moduledoc """
  Verified actor assertion (workspace ADR-16 Decision 9 — **the crux**).

  The kernel does **not** trust a plaintext `{viewer, scopes}` (ADR-7's nominal
  boundary: a channel bug / stale session / confused deputy could spoof it). Each
  request instead carries a **signed** actor assertion; the kernel verifies it and
  **derives** the effective `{uuid, scopes, caps}` from its OWN records
  (`identity_link → app_user → group_scope_map / role_grant`). The channel says
  *who authenticated*; the kernel decides *what they may do*. This is what makes
  the kernel the real sole authority on the single box.

  ## Wire contract (so the channel — hive, step 6 — implements it verbatim)

  A compact **HS256 JWT**, shared secret (`SWARM_ACTOR_SECRET`, in `hive/secrets.env`,
  gitignored; mTLS is the later upgrade). The verifier is deliberately strict —
  `alg` is pinned to `HS256`, so `alg:"none"` and RS/HS confusion are rejected
  outright (the classic JWT attack class is designed out, not merely guarded).

      header  = {"alg":"HS256","typ":"JWT"}
      payload = {"aud": "swarm.actor.v1", "sub": <IdP stable subject>,
                 "provider": "keycloak"|"local", "sid": <opaque session id>,
                 "iat": <unix s>, "exp": <unix s>}
      token   = b64url(header) "." b64url(payload) "." b64url(HMAC_SHA256(secret, signing_input))

  The payload carries only *who* + session + expiry — **never** scopes/roles/uuid.
  Those are derived kernel-side, so a forged or replayed token cannot widen access.
  `aud` pins the token's **purpose** (`swarm.actor.v1`), required by `verify/2`: even a
  token correctly signed with the shared secret for a *different* use (e.g. a session
  cookie) cannot be replayed as an actor assertion (cross-JWT confusion is designed out).
  Provisioning of the user record (login/names/emails/groups from the OIDC claims)
  is the JIT `Swarm.Identity.upsert_from_claims/1` path at login — separate from this
  per-request resolve.

  `resolve/2` fails **closed**: no secret configured, bad signature/audience, expired,
  unknown `(provider, subject)`, or a non-`active` account all yield `{:error, reason}`
  and never a partial actor.

  ## Council caveats (2026-07-01, codex + llama3.3:70b — convergent SOUND-WITH-CAVEATS)

  Crypto core confirmed sound. Accepted MVP posture, hardening deferred to
  `board/todo/actor-assertion-hardening`:
  - **Replay within `exp`:** `sid` is carried but not validated against a session store
    (sessions live channel-side, hive ADR-1). Bounded by a **short `exp`** (issue ≤5 min);
    logout is not instant until a session-revocation mechanism lands. Use short-lived tokens.
  - **Scope staleness:** derived scopes reflect the last JIT login's group state; IdP-side
    revocation lags until the next login/refresh. Acceptable for the small trusted cohort.
  - **Secret:** env-only, fails closed if unset. Use a high-entropy (≥32-byte) secret; key
    rotation (`kid` + current/previous window) is deferred to production hardening.
  - **Cutover (step 6):** the legacy plaintext `viewer/scopes` gRPC path is still trusted
    until the channel signs assertions; enforcement (reject plaintext, ignore wire scopes)
    is a **required step-6 gate**, not built here to avoid an unwired flag.
  """

  alias Swarm.Identity

  @type actor :: %{
          uuid: String.t(),
          login: String.t(),
          scopes: [String.t()],
          caps: [String.t()],
          sid: String.t() | nil
        }
  @type reason ::
          :no_secret
          | :malformed
          | :bad_alg
          | :bad_signature
          | :bad_audience
          | :expired
          | :invalid_claims
          | :unknown_actor
          | :inactive

  @header %{"alg" => "HS256", "typ" => "JWT"}
  # The token's purpose binding (council: prevents cross-JWT confusion if the shared
  # secret ever signs another token type). Required by verify/2.
  @audience "swarm.actor.v1"

  @doc """
  Verify a signed assertion and **derive** the effective actor from the kernel's own
  records. The security-path entry point. `opts`: `:secret`, `:leeway_s` (both fall
  back to `config :swarm, :actor`).
  """
  @spec resolve(String.t(), keyword()) :: {:ok, actor()} | {:error, reason()}
  def resolve(token, opts \\ []) do
    with {:ok, claims} <- verify(token, opts),
         {:ok, provider, subject} <- identity_claims(claims),
         %{} = user <- Identity.user_by_link(provider, subject) || {:error, :unknown_actor},
         :active <- account_status(user) do
      {:ok,
       %{
         uuid: user.id,
         login: user.login,
         scopes: Identity.scopes_for(user.id),
         caps: Identity.caps_for(user.id),
         sid: Map.get(claims, "sid")
       }}
    else
      {:error, reason} -> {:error, reason}
      :inactive -> {:error, :inactive}
    end
  end

  @doc """
  Verify a signed assertion's signature + expiry and return its claims. Does NOT
  touch the store — pure crypto + time. `opts`: `:secret`, `:leeway_s`,
  `:audience` (default the actor audience — pass the provision audience to
  verify a provision token; the binding prevents cross-use).

  TTL sanity (council codex, jit-provision-rpc): `iat` must be present, not in
  the future beyond leeway, and `exp - iat` may not exceed the 300s wire
  contract (`config :swarm, :actor, max_ttl_s`) — a signer bug or replayed
  long-lived token fails closed regardless of `exp` itself.
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def verify(token, opts \\ []) when is_binary(token) do
    with {:ok, secret} <- secret(opts),
         {:ok, h_b64, p_b64, sig_b64} <- split(token),
         :ok <- check_alg(h_b64),
         :ok <- check_sig(h_b64 <> "." <> p_b64, sig_b64, secret),
         {:ok, claims} <- decode_json(p_b64),
         :ok <- check_audience(claims, Keyword.get(opts, :audience, @audience)),
         :ok <- check_exp(claims, leeway(opts)) do
      check_ttl(claims, leeway(opts))
    end
  end

  @provision_audience "swarm.provision.v1"

  @doc "The provision-token audience (ADR-16 D3 wire contract)."
  @spec provision_audience() :: String.t()
  def provision_audience, do: @provision_audience

  @doc """
  Verify a **provision token** (aud `swarm.provision.v1`) and return the bound,
  normalized claim set for `Swarm.Identity.provision_from_claims/1`. The WHOLE
  claim set (login/names/email/groups) lives inside the signed payload — nothing
  authority-bearing arrives as a plain request field (council: unsigned groups
  would be self-asserted scopes). Non-string/blank group entries are dropped;
  a missing/blank `login` fails closed (`:invalid_claims`).
  """
  @spec verify_provision(String.t(), keyword()) ::
          {:ok, Swarm.Identity.claims()} | {:error, reason()}
  def verify_provision(token, opts \\ []) when is_binary(token) do
    with {:ok, claims} <- verify(token, Keyword.put(opts, :audience, @provision_audience)),
         {:ok, provider, subject} <- identity_claims(claims),
         {:ok, login} <- non_blank(claims["login"]) do
      {:ok,
       %{
         provider: provider,
         subject: subject,
         login: login,
         first_name: str_or_nil(claims["first_name"]),
         last_name: str_or_nil(claims["last_name"]),
         nickname: str_or_nil(claims["nickname"]),
         emails: provision_emails(claims["email"]),
         groups:
           claims["groups"]
           |> List.wrap()
           |> Enum.filter(&(is_binary(&1) and &1 != ""))
       }}
    end
  end

  @doc """
  Sign an assertion (HS256). For tests + as the reference the channel mirrors;
  production signing is the channel's job (hive, step 6). `opts`: `:secret`,
  `:exp_in` (seconds from now, default 300 — the wire contract's ceiling),
  `:exp` (absolute unix s, wins). Pass `"aud" => provision_audience()` in the
  payload to sign a provision token.
  """
  @spec sign(map(), keyword()) :: String.t()
  def sign(payload, opts \\ []) when is_map(payload) do
    {:ok, secret} = secret(opts)
    now = System.system_time(:second)
    exp = Keyword.get(opts, :exp, now + Keyword.get(opts, :exp_in, 300))

    payload =
      payload
      |> Map.put_new("aud", @audience)
      |> Map.put_new("iat", now)
      |> Map.put("exp", exp)

    signing_input = b64(Jason.encode!(@header)) <> "." <> b64(Jason.encode!(payload))
    signing_input <> "." <> b64(mac(signing_input, secret))
  end

  # ── verification steps ─────────────────────────────────────────────────

  @spec secret(keyword()) :: {:ok, binary()} | {:error, :no_secret}
  defp secret(opts) do
    case Keyword.get(opts, :secret) || Application.get_env(:swarm, :actor, [])[:secret] do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :no_secret}
    end
  end

  @spec leeway(keyword()) :: non_neg_integer()
  defp leeway(opts) do
    Keyword.get(opts, :leeway_s) || Application.get_env(:swarm, :actor, [])[:leeway_s] || 0
  end

  @spec split(String.t()) :: {:ok, String.t(), String.t(), String.t()} | {:error, :malformed}
  defp split(token) do
    case String.split(token, ".") do
      [h, p, s] when h != "" and p != "" and s != "" -> {:ok, h, p, s}
      _ -> {:error, :malformed}
    end
  end

  @spec check_alg(String.t()) :: :ok | {:error, :bad_alg | :malformed}
  defp check_alg(h_b64) do
    with {:ok, header} <- decode_json(h_b64) do
      # Pin HS256 — reject "none" and any asymmetric alg (kills alg-confusion).
      if header["alg"] == "HS256", do: :ok, else: {:error, :bad_alg}
    end
  end

  @spec check_sig(String.t(), String.t(), binary()) :: :ok | {:error, :bad_signature}
  defp check_sig(signing_input, sig_b64, secret) do
    with {:ok, provided} <- url_decode(sig_b64),
         expected <- mac(signing_input, secret),
         true <-
           byte_size(provided) == byte_size(expected) and
             :crypto.hash_equals(provided, expected) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  end

  @spec check_audience(map(), String.t()) :: :ok | {:error, :bad_audience}
  defp check_audience(%{"aud" => aud}, expected) when aud == expected, do: :ok
  defp check_audience(_, _), do: {:error, :bad_audience}

  # TTL sanity: iat present + not-future (beyond leeway) + lifetime within the
  # wire contract's ceiling. See verify/2 doc.
  @spec check_ttl(map(), non_neg_integer()) :: {:ok, map()} | {:error, :invalid_claims}
  defp check_ttl(claims, leeway) do
    max_ttl = Application.get_env(:swarm, :actor, [])[:max_ttl_s] || 300
    now = System.system_time(:second)

    case {claims["iat"], claims["exp"]} do
      {iat, exp} when is_integer(iat) and is_integer(exp) ->
        if iat <= now + leeway and exp - iat <= max_ttl + leeway do
          {:ok, claims}
        else
          {:error, :invalid_claims}
        end

      _ ->
        {:error, :invalid_claims}
    end
  end

  @spec non_blank(term()) :: {:ok, String.t()} | {:error, :invalid_claims}
  defp non_blank(v) when is_binary(v) do
    if String.trim(v) == "", do: {:error, :invalid_claims}, else: {:ok, v}
  end

  defp non_blank(_), do: {:error, :invalid_claims}

  @spec str_or_nil(term()) :: String.t() | nil
  defp str_or_nil(v) when is_binary(v) and v != "", do: v
  defp str_or_nil(_), do: nil

  # The channel relays the IdP's (verified) primary email, one per token.
  @spec provision_emails(term()) :: [map()]
  defp provision_emails(email) when is_binary(email) and email != "",
    do: [%{email: email, verified: true, primary: true}]

  defp provision_emails(_), do: []

  @spec check_exp(map(), non_neg_integer()) :: :ok | {:error, :expired | :invalid_claims}
  defp check_exp(claims, leeway) do
    case claims["exp"] do
      exp when is_integer(exp) ->
        if System.system_time(:second) <= exp + leeway, do: :ok, else: {:error, :expired}

      _ ->
        # An assertion with no expiry is invalid — fail closed, never eternal.
        {:error, :invalid_claims}
    end
  end

  @spec identity_claims(map()) :: {:ok, String.t(), String.t()} | {:error, :invalid_claims}
  defp identity_claims(%{"provider" => p, "sub" => s})
       when is_binary(p) and p != "" and is_binary(s) and s != "",
       do: {:ok, p, s}

  defp identity_claims(_), do: {:error, :invalid_claims}

  @spec account_status(map()) :: :active | :inactive
  defp account_status(%{status: "active"}), do: :active
  defp account_status(_), do: :inactive

  # ── primitives ───────────────────────────────────────────────────────────

  @spec mac(binary(), binary()) :: binary()
  defp mac(data, secret), do: :crypto.mac(:hmac, :sha256, secret, data)

  @spec b64(binary()) :: String.t()
  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  @spec url_decode(String.t()) :: {:ok, binary()} | :error
  defp url_decode(s), do: Base.url_decode64(s, padding: false)

  @spec decode_json(String.t()) :: {:ok, map()} | {:error, :malformed}
  defp decode_json(b64) do
    with {:ok, raw} <- url_decode(b64),
         {:ok, map} when is_map(map) <- Jason.decode(raw) do
      {:ok, map}
    else
      _ -> {:error, :malformed}
    end
  end
end
