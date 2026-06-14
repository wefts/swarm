defmodule Swarm.Ports.Worker do
  @moduledoc """
  Worker port (Domain 3): a cheap, specialized agent that acts on graph state
  (observer, linker, classifier, …).

  Behaviour only — concrete workers are supervised adapters outside the kernel.
  Coordination (claim/lease, fencing) is the kernel's job (ADR-1/ADR-2), not the
  worker's.
  """

  @typedoc "A unit of work claimed from the graph."
  @type task :: map()

  @doc "Handle one task. Fail-loud: a typed result the caller must branch on."
  @callback handle(task()) :: {:ok, map()} | {:error, term()}

  @doc "Report worker identity and the task types it handles."
  @callback describe() :: map()
end
