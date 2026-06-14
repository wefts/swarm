defmodule Swarm.Ports.Connector do
  @moduledoc """
  Connector port (Domain 2): an inbound adapter that turns an external source
  into normalized events on the bus.

  Behaviour only — concrete connectors (files, git, wiki, …) are adapters that
  live outside the kernel and are discovered at runtime. The kernel depends on
  this contract, never on an adapter.
  """

  @typedoc "A normalized ingest event. Shape is fixed by the Protobuf contract."
  @type event :: map()

  @typedoc "Connector self-description for the registry (name, capabilities, health)."
  @type info :: map()

  @doc "Stream normalized events from the source into the kernel."
  @callback stream(opts :: keyword()) :: Enumerable.t()

  @doc "Report connector identity, capability, and health for the registry."
  @callback describe() :: info()
end
