defmodule Swarm.Ports.Channel do
  @moduledoc """
  Channel port (Domain 11): talk to a user or front end under the single-voice
  rule. A channel renders output and accepts input; it holds no cognition.

  Behaviour only — concrete channels (CLI, web, chat) are adapters outside the
  kernel. The single-voice gate lives in the kernel, not in the adapter.

  Rendering is **deterministic and channel-owned** — the kernel emits structured
  facts (answer, `status`, citations, confidence); the channel formats them, and
  a model never chooses the presentation of a value, link, or id. See
  `../../../docs/standards/presentation-determinism.md`.
  """

  @typedoc "An outbound message to a user/front."
  @type message :: map()

  @doc "Deliver a message on this channel."
  @callback send(message()) :: :ok | {:error, term()}

  @doc "Report channel identity and capabilities."
  @callback describe() :: map()
end
