defmodule Swarm.Graph.Strength do
  @moduledoc """
  Stigmergic trace strength with saturation and decay (ADR-9). Pure functions;
  λ and S come from config (the tuning inventory, ADR-8), never hardcoded.

      strength = f(seen_count) * exp(-λ · age)
      f(n)     = log(1+n) / (log(1+n) + S)     # Hill — saturating, not linear

  Linear `f` would create immortal edges; decay is the dominant pole. `seen_count`
  must come only from provenance-distinct events (enforced in the data layer), or
  a confirmation loop would inflate strength.
  """

  alias Swarm.Config

  @doc "Hill saturation f(n) = log(1+n)/(log(1+n)+S). Range [0,1), monotone in n."
  @spec saturation(non_neg_integer()) :: float()
  def saturation(seen_count) when is_integer(seen_count) and seen_count >= 0 do
    l = :math.log(1 + seen_count)
    l / (l + Config.saturation_s())
  end

  @doc "Time decay exp(-λ · age_days). `age_seconds` >= 0; decay(0) == 1.0."
  @spec decay(number()) :: float()
  def decay(age_seconds) when is_number(age_seconds) and age_seconds >= 0 do
    :math.exp(-Config.decay_lambda() * age_seconds / 86_400.0)
  end

  @doc "Trace strength = f(seen_count) * decay(age)."
  @spec strength(non_neg_integer(), number()) :: float()
  def strength(seen_count, age_seconds) do
    saturation(seen_count) * decay(age_seconds)
  end

  @doc """
  Edge/node reliability at read: `r_0 * exp(-λ · age)` (ADR-3 — source and time
  are absorbed into `r_i` before aggregation). `r_0` should already include
  `w_source`.
  """
  @spec decayed_reliability(float(), number()) :: float()
  def decayed_reliability(r0, age_seconds) when is_number(r0) do
    r0 * decay(age_seconds)
  end
end
