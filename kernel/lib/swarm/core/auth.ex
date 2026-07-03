defmodule Swarm.Core.Auth do
  @moduledoc """
  The Core API auth seam (workspace ADR-16 D9). Turns the wire identity into an
  effective context, **verifying + deriving** rather than trusting where it can.

  Two entry points, by RPC class:

  - `legacy_context/2` — for the ORIGINAL RPCs (Ask/KbSearch/Deliberation/…), which
    still carry a plaintext `viewer` from the live channel. **Dual-accept** (the
    `auth_mode` flag, default `:dual`): if the `viewer` is a valid *signed* assertion
    it is verified and `{uuid, scopes}` derived (ignoring wire scopes); otherwise it
    falls back to the legacy plaintext `viewer` + wire scopes so the live channel keeps
    working during the step-6b migration. `:strict` rejects unsigned (the post-cutover
    mode, shipped WITH 6b); `:legacy` never verifies.
  - `actor/1` — for the NEW identity/privacy RPCs (conversations, admin). Always
    **strict**: a verified actor or `{:error, _}`. These are born secure — no legacy
    plaintext caller exists, and they are the privacy-critical surface.

  The hard cutover (rejecting plaintext on the legacy RPCs) is NOT shipped here — it
  flips with 6b, else the live channel breaks.
  """

  require Logger

  alias Swarm.Actor

  @type context :: %{viewer: String.t(), scopes: [String.t()]}

  @doc "The configured auth mode (`:dual` default | `:strict` | `:legacy`)."
  @spec mode() :: :dual | :strict | :legacy
  def mode, do: Application.get_env(:swarm, :core_api, [])[:auth_mode] || :dual

  @doc """
  Effective `{viewer, scopes}` for a legacy RPC. `{:ok, context}` normally;
  `{:error, :unauthenticated}` only in `:strict` mode with no valid assertion.
  """
  @spec legacy_context(String.t(), [String.t()]) :: {:ok, context()} | {:error, :unauthenticated}
  def legacy_context(viewer, wire_scopes) do
    case maybe_resolve(viewer) do
      {:ok, a} -> {:ok, %{viewer: a.uuid, scopes: a.scopes}}
      {:error, _} -> unverified(viewer, wire_scopes)
    end
  end

  # A viewer that did NOT verify. In :strict ⇒ reject. In :legacy ⇒ trust plaintext.
  # In :dual, distinguish (council): a viewer that is ASSERTION-SHAPED (a JWT `h.p.s`)
  # but failed verification is a bad/expired/forged token — do NOT trust the literal
  # string as a plaintext id (that would create a ghost identity); fail closed to
  # anonymous public + log. Only a non-assertion-shaped viewer is trusted as legacy
  # plaintext (that is the live channel's real behavior until 6b).
  @spec unverified(String.t(), [String.t()]) :: {:ok, context()} | {:error, :unauthenticated}
  defp unverified(viewer, wire_scopes) do
    case mode() do
      :strict ->
        {:error, :unauthenticated}

      :legacy ->
        {:ok, %{viewer: viewer, scopes: norm_scopes(wire_scopes)}}

      :dual ->
        dual_fallback(viewer, wire_scopes)
    end
  end

  @spec dual_fallback(String.t(), [String.t()]) :: {:ok, context()}
  defp dual_fallback(viewer, wire_scopes) do
    if assertion_shaped?(viewer) do
      Logger.warning(
        "core.auth: an assertion-shaped viewer failed verification; refusing to treat it " <>
          "as a plaintext id (dual mode) — falling back to anonymous public"
      )

      {:ok, %{viewer: "", scopes: ["public"]}}
    else
      log_plaintext_viewer(viewer)
      {:ok, %{viewer: viewer, scopes: norm_scopes(wire_scopes)}}
    end
  end

  # Shadow-log every NON-EMPTY plaintext viewer actually trusted (council:
  # gemini-3.1-pro, 6b.7 cutover readiness) — an empty viewer is the ordinary
  # anonymous/pre-auth path and not worth flagging. Once :strict lands, any
  # caller still showing up here would silently degrade to anonymous public
  # rather than erroring (Server.ctx/2) — this log is the only way to notice a
  # not-yet-migrated identity BEFORE that happens, not after.
  @spec log_plaintext_viewer(String.t()) :: :ok
  defp log_plaintext_viewer(""), do: :ok

  defp log_plaintext_viewer(viewer) do
    Logger.warning(
      "core.auth: plaintext viewer=#{viewer} accepted in :dual mode (not a signed " <>
        "assertion) — will degrade to anonymous public once :strict is enabled; verify " <>
        "this identity is migrated (ADR-16 step 6b.6) before the cutover"
    )
  end

  # A compact JWT is exactly three non-empty dot-separated segments; a plaintext
  # viewer (a login or a uuid) has none.
  @spec assertion_shaped?(String.t()) :: boolean()
  defp assertion_shaped?(viewer) do
    case String.split(viewer, ".") do
      [a, b, c] when a != "" and b != "" and c != "" -> true
      _ -> false
    end
  end

  @doc "Resolve a verified actor for a strict identity/privacy RPC."
  @spec actor(String.t()) :: {:ok, Actor.actor()} | {:error, Actor.reason()}
  def actor(assertion), do: Actor.resolve(assertion)

  @doc """
  Normalize an empty wire scope list to public-only (default-deny baseline).

  `private` is clamped out of any WIRE scope list (person-scope-leak-guard,
  council codex): it is the per-user chat-privacy scope and is never derivable
  from a grant, so a plaintext caller in `:dual`/`:legacy` must not be able to
  request it either. A caller asking for private-only ends up with `[]` —
  fail-closed, sees nothing.
  """
  @spec norm_scopes([String.t()]) :: [String.t()]
  def norm_scopes([]), do: ["public"]
  def norm_scopes(scopes), do: Enum.reject(scopes, &(&1 == "private"))

  # Only attempt cryptographic verification in modes that trust signatures; in
  # :legacy we never verify. A plaintext viewer simply fails to parse and falls back.
  @spec maybe_resolve(String.t()) :: {:ok, Actor.actor()} | {:error, term()}
  defp maybe_resolve(viewer) do
    if mode() in [:dual, :strict], do: Actor.resolve(viewer), else: {:error, :legacy}
  end
end
