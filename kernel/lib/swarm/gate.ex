defmodule Swarm.Gate do
  @moduledoc """
  The decision gate (Domain 5): cheap-and-constant by default, expensive-and-rare
  on escalation. Mechanism/policy split — `Matcher` returns a raw score, `Bands`
  owns the thresholds, this module routes and records cost.

  - **route/2** picks a tier: `:tier0` (canned), `:tier_tools` (deterministic
    graph/data answer), or `:escalate` (to the consilium — stubbed until Task 07).
  - **verify_then_climb/1** is the post-hoc, *free* deterministic check: run the
    cheap path first, climb only if the output is empty or self-declared
    inability. Confident-wrong is the known hole (ADR-7) — a different-family
    judge mitigates it in Task 07.
  - Visibility is enforced through `Swarm.Gate.Visibility` (the single point).
  - Graceful degradation: if the embedder is down, fall back to keyword routing
    with a conservative floor (unknown ⇒ escalate).
  """

  alias Swarm.Gate.{Bands, Matcher, Telemetry}

  @type tier :: :tier0 | :tier_tools | :escalate
  @type decision :: %{tier: tier(), score: float(), intent: atom() | nil, reason: atom()}

  # Handle threshold DERIVED empirically by `Swarm.Gate.Eval` on the frozen
  # 10-message labeled set with bge-m3 (precision_floor 0.9): off-topic messages
  # scored 0.30/0.36, cheap-tier messages 0.68–0.87, so the precision-0.9
  # boundary is 0.677. NOT a hand-set magic number; re-derive on embed-model
  # change (ADR-8).
  @handle_threshold 0.677

  @inability ~r/\b(i (?:don't|do not) know|cannot help|not sure|no idea|unable to)\b/i

  @doc "The empirically-derived default bands (see `Swarm.Gate.Eval`)."
  @spec default_bands() :: Bands.t()
  def default_bands, do: %Bands{handle: @handle_threshold}

  @doc """
  Route a message to a tier. `opts` may carry `:bands`, `:embedder`,
  `:prototypes` (all default to production). Records cost telemetry.
  """
  @spec route(String.t(), keyword()) :: decision()
  def route(message, opts \\ []) do
    bands = Keyword.get(opts, :bands, default_bands())

    decision =
      case Matcher.score(message, opts) do
        {:ok, match} -> by_band(Bands.classify(bands, match.score), match)
        {:error, _reason} -> degraded(message)
      end

    Telemetry.count(decision.tier)
    decision
  end

  @doc """
  Verify-then-climb: inspect a cheap-tier output and decide whether to climb.
  Empty or self-declared inability ⇒ `:climb`; otherwise `:keep`.
  """
  @spec verify_then_climb(term()) :: :keep | :climb
  def verify_then_climb(output) do
    if empty?(output) or inability?(output), do: :climb, else: :keep
  end

  @spec by_band(:handle | :escalate, Matcher.match()) :: decision()
  defp by_band(:handle, match),
    do: %{tier: match.tier, score: match.score, intent: match.intent, reason: :matched}

  defp by_band(:escalate, match),
    do: %{tier: :escalate, score: match.score, intent: match.intent, reason: :low_confidence}

  @spec degraded(String.t()) :: decision()
  defp degraded(message),
    do: %{tier: Matcher.keyword_fallback(message), score: 0.0, intent: nil, reason: :degraded}

  defp empty?(output), do: output in [nil, "", [], %{}]

  defp inability?(text) when is_binary(text), do: Regex.match?(@inability, text)
  defp inability?(_), do: false
end
