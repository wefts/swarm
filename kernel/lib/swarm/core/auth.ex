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
        if assertion_shaped?(viewer) do
          Logger.warning(
            "core.auth: an assertion-shaped viewer failed verification; refusing to treat it " <>
              "as a plaintext id (dual mode) — falling back to anonymous public"
          )

          {:ok, %{viewer: "", scopes: ["public"]}}
        else
          {:ok, %{viewer: viewer, scopes: norm_scopes(wire_scopes)}}
        end
    end
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

  @doc "Normalize an empty wire scope list to public-only (default-deny baseline)."
  @spec norm_scopes([String.t()]) :: [String.t()]
  def norm_scopes([]), do: ["public"]
  def norm_scopes(scopes), do: scopes

  # Only attempt cryptographic verification in modes that trust signatures; in
  # :legacy we never verify. A plaintext viewer simply fails to parse and falls back.
  @spec maybe_resolve(String.t()) :: {:ok, Actor.actor()} | {:error, term()}
  defp maybe_resolve(viewer) do
    if mode() in [:dual, :strict], do: Actor.resolve(viewer), else: {:error, :legacy}
  end
end
