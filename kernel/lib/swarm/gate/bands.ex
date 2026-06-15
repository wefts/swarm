defmodule Swarm.Gate.Bands do
  @moduledoc """
  Routing bands (ADR-8) — **policy**, kept apart from the matcher's raw score
  (mechanism/policy split). Thresholds are *derived from measured distributions*,
  never set by feel, and must be re-derived per embedding model.

  Two outcomes: `:handle` (trust the matched cheap tier) above the handle
  threshold, else `:escalate`. The gray zone collapses to escalate — bias to
  escalate under doubt (Domain 5).
  """

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: float()}

  @doc """
  Derive the handle threshold from labeled `{score, correct?}` samples: the
  lowest score `s` such that predictions with score ≥ `s` hold precision ≥
  `:precision_floor` (default 0.9). Reproducible: same data → same threshold.
  """
  @spec derive([{float(), boolean()}], keyword()) :: t()
  def derive(labeled, opts \\ []) when is_list(labeled) do
    floor = Keyword.get(opts, :precision_floor, 0.9)

    handle =
      labeled
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.find(1.0, fn s -> precision_at_or_above(labeled, s) >= floor end)

    %__MODULE__{handle: handle}
  end

  @doc "Classify a raw score against the bands."
  @spec classify(t(), float()) :: :handle | :escalate
  def classify(%__MODULE__{handle: h}, score) when is_number(score) do
    if score >= h, do: :handle, else: :escalate
  end

  @spec precision_at_or_above([{float(), boolean()}], float()) :: float()
  defp precision_at_or_above(labeled, threshold) do
    kept = Enum.filter(labeled, fn {score, _ok} -> score >= threshold end)

    case kept do
      [] -> 0.0
      _ -> Enum.count(kept, fn {_s, ok} -> ok end) / length(kept)
    end
  end
end
