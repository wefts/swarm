defmodule Swarm.Gate.Eval do
  @moduledoc """
  Tiny eval harness for the routing bands (ADR-8): score a labeled message set
  with a given embedder, then derive the handle threshold from the measured
  right/wrong score distribution. The eval exists before the feature it gates,
  and the bands are re-derived per embedding model — never hand-set.

  Run with the real `bge-m3` embedder to (re)derive `Swarm.Gate.default_bands/0`.
  """

  alias Swarm.Gate.{Bands, Matcher}

  @typedoc "A labeled routing example: message and the tier that should handle it."
  @type sample :: %{message: String.t(), expected: :tier0 | :tier_tools | :escalate}

  # Frozen, externally-authored labels (small but enough to derive a threshold).
  @labeled [
    %{message: "hi there", expected: :tier0},
    %{message: "hello, good morning", expected: :tier0},
    %{message: "thanks, that helps", expected: :tier0},
    %{message: "goodbye for now", expected: :tier0},
    %{message: "what changed in the project recently", expected: :tier_tools},
    %{message: "show me the current status", expected: :tier_tools},
    %{message: "list recent activity", expected: :tier_tools},
    %{message: "find files related to billing", expected: :tier_tools},
    %{message: "explain the philosophical implications of quantum gravity", expected: :escalate},
    %{message: "draft a detailed strategy memo on macroeconomic policy", expected: :escalate}
  ]

  @spec labeled() :: [sample()]
  def labeled, do: @labeled

  @doc """
  Derive bands using `embedder`. Returns `{bands, scored}` where `scored` is the
  measured `{score, correct?}` distribution (for inspection/documentation).
  """
  @spec derive_bands(keyword()) :: {Bands.t(), [{float(), boolean()}]}
  def derive_bands(opts \\ []) do
    scored =
      Enum.map(@labeled, fn %{message: msg, expected: expected} ->
        {:ok, match} = Matcher.score(msg, opts)
        {match.score, match.tier == expected}
      end)

    {Bands.derive(scored, opts), scored}
  end
end
