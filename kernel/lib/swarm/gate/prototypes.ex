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
