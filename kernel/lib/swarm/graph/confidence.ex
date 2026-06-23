defmodule Swarm.Graph.Confidence do
  @moduledoc """
  Confidence calculus (ADR-3) — one coherent probabilistic algebra. Pure
  functions: no I/O, same input → same output.

  - **Chain / AND:** `product(r_i)` in log-space (longer inference is naturally
    less reliable; no separate length-decay hack).
  - **Confirmation / OR:** `max` within a shared-ancestor group (collapse
    correlated paths to their strongest), noisy-OR `1 - prod(1 - p_j)` across
    independent groups. No possibilistic `min` mixed in.

  Each `r_i` must already absorb source and time (`r_0 * w_source *
  exp(-λ·age)`, see `Swarm.Graph.Strength`) before aggregation. Output is a
  heuristic score until calibrated (ADR-3/ADR-8).
  """

  # r below this floor is treated as this floor so log stays finite.
  @floor 1.0e-12

  @doc "Chain (AND): product of per-hop reliabilities, computed in log-space."
  @spec chain([float()]) :: float()
  def chain([]), do: 1.0

  def chain(reliabilities) do
    reliabilities
    |> Enum.reduce(0.0, fn r, acc -> acc + safe_log(r) end)
    |> :math.exp()
  end

  @doc "Noisy-OR across independent evidence: `1 - prod(1 - p_j)`."
  @spec noisy_or([float()]) :: float()
  def noisy_or([]), do: 0.0

  def noisy_or(probabilities) do
    1.0 - Enum.reduce(probabilities, 1.0, fn p, acc -> acc * (1.0 - p) end)
  end

  @doc """
  Combine path confidences grouped by lineage: `max` within each shared-ancestor
  group, then noisy-OR across the independent groups. `groups` is a list of
  groups; each group is a list of path confidences.
  """
  @spec combine([[float()]]) :: float()
  def combine([]), do: 0.0

  def combine(groups) do
    groups
    |> Enum.map(&group_max/1)
    |> noisy_or()
  end

  # LLM-generated zones (T12): a trace of any of these kinds is model output, not
  # external evidence, so they are never independent corroboration of each other.
  @generated_kinds ~w(claim hypothesis derived)

  @doc """
  Combine typed contributions `[{confidence, kind}]` (T12, N3 defense). All
  **LLM-generated** contributions (`#{Enum.join(@generated_kinds, "`/`")}`)
  collapse into ONE group — co-located agent chatter is **never** independent
  corroboration, no matter how many models say it — while each external
  (`observation` / `durable_fact`) contribution is its own independent group.
  Then the usual `combine/1`: max within, noisy-OR across.

  Three claims of 0.8 → 0.8 (one group); two independent observations of 0.8 →
  0.96 (noisy-OR). A hallucination cannot inflate confidence by repetition.

  This is the typed companion to `combine/1`, applied wherever cross-origin
  corroboration is computed; the single-source `Swarm.Graph.Traverse` path is one
  shared-ancestor group (`max`) and does not reach this question (large-scale
  multi-origin grouping is the deferred open problem of ADR-3 / the T1 spike).
  """
  @spec combine_typed([{float(), String.t()}]) :: float()
  def combine_typed(contributions) do
    {generated, external} =
      Enum.split_with(contributions, fn {_c, kind} -> kind in @generated_kinds end)

    generated_group = Enum.map(generated, fn {c, _} -> c end)
    external_groups = Enum.map(external, fn {c, _} -> [c] end)

    groups =
      if generated_group == [], do: external_groups, else: [generated_group | external_groups]

    combine(groups)
  end

  @spec group_max([float()]) :: float()
  defp group_max([]), do: 0.0
  defp group_max(probabilities), do: Enum.max(probabilities)

  @spec safe_log(float()) :: float()
  defp safe_log(r) when r > @floor, do: :math.log(r)
  defp safe_log(_r), do: :math.log(@floor)
end
