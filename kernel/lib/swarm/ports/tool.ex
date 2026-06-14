defmodule Swarm.Ports.Tool do
  @moduledoc """
  Tool port (Domain 12): outward actions, funneled through one gateway where
  permission, rate-limit, audit, and dry-run live.

  Behaviour only — concrete tools are adapters behind the single boundary, never
  scattered call sites. Model-supplied action targets are re-authorized against
  a code-owned allowlist before invocation (ADR-7).
  """

  @typedoc "A requested outward action."
  @type action :: map()

  @doc "Invoke an outward action through the gateway (honors dry-run)."
  @callback invoke(action(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Report tool identity and the actions it exposes."
  @callback describe() :: map()
end
