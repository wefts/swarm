defmodule Swarm.Gate.Prototypes do
  @moduledoc """
  Intent prototypes for the routing matcher — config DATA, not policy. Each
  prototype maps example text to an intent and the cheap tier that handles it
  (`:tier0` canned / zero-LLM, `:tier_tools` deterministic graph/data answer).
  Thresholds (policy) live in `Swarm.Gate.Bands`.
  """

  @type prototype :: %{intent: atom(), tier: :tier0 | :tier_tools, text: String.t()}

  @prototypes [
    %{intent: :greeting, tier: :tier0, text: "hello hi hey good morning thanks thank you"},
    %{intent: :farewell, tier: :tier0, text: "bye goodbye see you later"},
    # Off-mission requests (T9): recognized at tier0 so they are DEFLECTED cheaply
    # (zero-LLM, never an escalation) — a poem/recipe must not burn a model call.
    %{
      intent: :off_topic,
      tier: :tier0,
      text: "write a poem tell a joke a recipe the weather sing a song write a story"
    },
    %{
      intent: :recall,
      tier: :tier_tools,
      text: "what changed recently show the project status list recent activity"
    },
    %{
      intent: :lookup,
      tier: :tier_tools,
      text: "find files related to this show connections between documents and people"
    }
  ]

  @spec all() :: [prototype()]
  def all, do: @prototypes
end
