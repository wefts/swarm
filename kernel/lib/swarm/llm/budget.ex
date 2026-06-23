defmodule Swarm.LLM.Budget do
  @moduledoc """
  Per-escalation token budget (T5, ADR-7 workspace). A model call is the expensive
  path; nothing structurally bounded what a single escalation could cost until
  here. This estimates a prompt's size and enforces a config **ceiling BEFORE the
  call**, so a raw tool/source payload can never be shipped to a model (the
  glpi-agent 385k-token scar — a tool dumped a raw payload into one call).

  Enforcement is **refuse fail-loud, never silent truncation**: an over-ceiling
  prompt returns `{:error, {:over_budget, estimated, ceiling}}`. Grounding /
  compression is the caller's job *upstream* (ground-before-model); the kernel's
  guarantee is only that an ungrounded payload is rejected, not quietly clipped.

  Per-escalation cost (tokens in/out) is emitted to telemetry so a regression is
  observable.
  """

  @telemetry_event [:swarm, :llm, :escalation]

  @typedoc "Refusal: the estimate exceeded the ceiling."
  @type over_budget :: {:over_budget, non_neg_integer(), pos_integer()}

  @doc """
  Rough token estimate: bytes ÷ 4. A cheap structural proxy, **not a tokenizer**.
  Roughly right for Latin prose; it can *under-count* adversarial input (pure
  whitespace/punctuation) and non-Latin scripts (CJK ≈ 3 bytes but ~1 token/char).
  It is more than adequate against a catastrophic raw dump (the 385k scar is ~12×
  the default ceiling, so the margin swamps the estimation error); near the
  boundary it is approximate, not exact. A real tokenizer would tighten it.
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text), do: div(byte_size(text), 4)

  @doc "Ensure `prompt` fits `ceiling` tokens; refuse fail-loud otherwise."
  @spec ensure(String.t(), pos_integer()) :: :ok | {:error, over_budget()}
  def ensure(prompt, ceiling) when is_binary(prompt) and is_integer(ceiling) and ceiling > 0 do
    estimate = estimate_tokens(prompt)
    if estimate <= ceiling, do: :ok, else: {:error, {:over_budget, estimate, ceiling}}
  end

  @doc """
  Emit one escalation's cost to telemetry: estimated tokens in/out (computed by
  the caller, so panel fan-out is counted, not just the judge), with `meta`
  carrying the outcome (`:ok` / `:over_budget`). Handlers (dashboards, regression
  alerts) attach to `telemetry_event/0`. A refusal emits too — an attempted
  over-budget escalation is the most security-relevant event to alert on.
  """
  @spec account(non_neg_integer(), non_neg_integer(), map()) :: :ok
  def account(tokens_in, tokens_out, meta \\ %{})
      when is_integer(tokens_in) and is_integer(tokens_out) do
    :telemetry.execute(@telemetry_event, %{tokens_in: tokens_in, tokens_out: tokens_out}, meta)
    :ok
  end

  @doc "The telemetry event name for per-escalation cost."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event
end
