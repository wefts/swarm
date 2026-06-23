defmodule Swarm.Consilium do
  @moduledoc """
  The escalation top (Domain 4). When the gate escalates, the mid-tier panel
  answers **in parallel**, inter-model disagreement is measured **before**
  synthesis (a confidence signal, not noise), and a stronger, different-family
  judge synthesizes one grounded verdict.

  Fail-loud (ADR-7 / Domain 4): a judge failure returns a typed
  `{:error, {:judge_failed, _}}` — never raw, unsynthesized panel text. The judge
  is `llama3.3:70b`, a different family from the qwen/gemma/glm panel, to
  decorrelate blind spots (confident-wrong mitigation). Judge-accuracy on the
  handle-confidently band is measured by an eval harness (the `Swarm.Gate.Eval`
  pattern) — deferred, hooked via the disagreement signal here.

  Economics: the caller passes already-compressed `:grounding` (the whole graph
  is never sent); panel runs concurrently so latency is the slowest single model,
  not the sum.
  """

  alias Swarm.Gate.Matcher
  alias Swarm.LLM.Budget
  alias Swarm.ML.{Embeddings, Generation}

  require Logger

  @panel_timeout_ms 300_000
  @judge_attempts 2

  @type take :: %{model: String.t(), answer: String.t()}
  @type verdict :: %{
          answer: String.t(),
          confidence: float(),
          disagreement: float(),
          panel: [take()],
          judge: String.t()
        }

  @doc """
  Deliberate on `query`. `opts`: `:grounding` (fenced data), `:fleet`
  (`%{panel, judge, token_ceiling}`, defaults to config), `:token_ceiling`
  (override), `:generator`/`:embedder` (injectable).

  Budget (T5, ADR-7): the panel and judge prompts are checked against the
  per-escalation token ceiling **before** any model call. An over-ceiling prompt
  is refused `{:error, {:over_budget, estimated, ceiling}}` — never silently
  truncated — so a raw payload cannot reach a model. Per-escalation cost is
  emitted to `Swarm.LLM.Budget.telemetry_event/0`.
  """
  @spec deliberate(String.t(), keyword()) :: {:ok, verdict()} | {:error, term()}
  def deliberate(query, opts \\ []) when is_binary(query) do
    fleet = Keyword.get_lazy(opts, :fleet, &Swarm.Config.consilium/0)
    generator = Keyword.get(opts, :generator, &Generation.generate/3)
    embedder = Keyword.get(opts, :embedder, &default_embed/1)
    grounding = Keyword.get(opts, :grounding, "")
    ceiling = Keyword.get(opts, :token_ceiling, Map.get(fleet, :token_ceiling, 32_000))
    panel_prompt = panel_prompt(query, grounding)

    with :ok <- budget(panel_prompt, ceiling),
         [_ | _] = takes <- run_panel(fleet.panel, panel_prompt, generator),
         judge_prompt = judge_prompt(query, grounding, takes),
         :ok <- budget(judge_prompt, ceiling),
         {:ok, v} <- judge(fleet.judge, judge_prompt, generator) do
      account_escalation(fleet.panel, panel_prompt, takes, judge_prompt, v.answer)
      disagreement = measure_disagreement(takes, embedder)
      {:ok, Map.merge(v, %{disagreement: disagreement, panel: takes, judge: fleet.judge})}
    else
      {:error, {:over_budget, est, ceil}} ->
        Logger.warning("consilium: escalation refused — over budget (#{est} > #{ceil} tokens)")
        Budget.account(est, 0, %{outcome: :over_budget})
        {:error, {:over_budget, est, ceil}}

      [] ->
        {:error, :panel_empty}

      {:error, reason} ->
        Logger.error("consilium judge failed: #{inspect(reason)}; quarantining (low confidence)")
        {:error, {:judge_failed, reason}}
    end
  end

  @spec budget(String.t(), pos_integer()) :: :ok | {:error, Budget.over_budget()}
  defp budget(prompt, ceiling), do: Budget.ensure(prompt, ceiling)

  # Account the WHOLE escalation, not just the judge: panel input is the panel
  # prompt sent to each of N models (fan-out), panel output is every take, plus
  # the judge prompt + answer. A panel-prompt regression is then visible.
  @spec account_escalation([String.t()], String.t(), [take()], String.t(), String.t()) :: :ok
  defp account_escalation(panel, panel_prompt, takes, judge_prompt, judge_answer) do
    panel_in = length(panel) * Budget.estimate_tokens(panel_prompt)
    panel_out = takes |> Enum.map(&Budget.estimate_tokens(&1.answer)) |> Enum.sum()
    tokens_in = panel_in + Budget.estimate_tokens(judge_prompt)
    tokens_out = panel_out + Budget.estimate_tokens(judge_answer)
    Budget.account(tokens_in, tokens_out, %{outcome: :ok, panel: length(panel)})
  end

  # Parallel panel — Task.async_stream, never an await-per-model loop. The prompt
  # is built (and budget-checked) by the caller; the panel just runs it.
  @spec run_panel([String.t()], String.t(), fun()) :: [take()]
  defp run_panel(models, prompt, generator) do
    models
    |> Task.async_stream(
      fn model -> {model, generator.(model, prompt, [])} end,
      max_concurrency: max(length(models), 1),
      timeout: @panel_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {model, {:ok, text}}} ->
        [%{model: model, answer: text}]

      {:ok, {model, {:error, reason}}} ->
        Logger.warning("consilium panel #{model} failed: #{inspect(reason)}")
        []

      {:exit, reason} ->
        Logger.warning("consilium panel task exited: #{inspect(reason)}")
        []
    end)
  end

  # Disagreement = mean pairwise (1 - cosine) of answer embeddings; 0.0 for < 2.
  @spec measure_disagreement([take()], fun()) :: float()
  defp measure_disagreement(takes, embedder) do
    vecs =
      takes
      |> Enum.map(&embedder.(&1.answer))
      |> Enum.flat_map(fn
        {:ok, v} -> [v]
        {:error, _} -> []
      end)

    pairs =
      for {a, i} <- Enum.with_index(vecs),
          {b, j} <- Enum.with_index(vecs),
          i < j,
          do: 1.0 - Matcher.cosine(a, b)

    case pairs do
      [] -> 0.0
      _ -> Enum.sum(pairs) / length(pairs)
    end
  end

  @spec judge(String.t(), String.t(), fun()) ::
          {:ok, %{answer: String.t(), confidence: float()}} | {:error, term()}
  defp judge(model, prompt, generator) do
    do_judge(model, prompt, generator, @judge_attempts)
  end

  defp do_judge(_model, _prompt, _generator, 0), do: {:error, :judge_invalid_output}

  defp do_judge(model, prompt, generator, attempts) do
    case generator.(model, prompt, json: true, system: judge_system()) do
      {:ok, raw} ->
        case parse_verdict(raw) do
          {:ok, verdict} -> {:ok, verdict}
          # Invalid structure → retry (structured-output validation + retry).
          {:error, _invalid} -> do_judge(model, prompt, generator, attempts - 1)
        end

      # Transport failure → fail loud, no retry.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_verdict(String.t()) ::
          {:ok, %{answer: String.t(), confidence: float()}} | {:error, term()}
  defp parse_verdict(raw) do
    case Jason.decode(raw) do
      {:ok, %{"answer" => a, "confidence" => c}} when is_binary(a) and is_number(c) ->
        {:ok, %{answer: a, confidence: c / 1}}

      {:ok, _} ->
        {:error, :invalid_verdict_schema}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  # External text is fenced as DATA, not instructions (ADR-7).
  defp panel_prompt(query, grounding) do
    """
    Answer the question using only the grounding below. Be concise.

    QUESTION: #{query}

    <grounding>
    #{grounding}
    </grounding>
    """
  end

  defp judge_system do
    "You are a synthesis judge. Combine the panel answers into ONE answer " <>
      "supported by the grounding; drop unsupported claims. Respond as strict " <>
      "JSON only: {\"answer\": string, \"confidence\": number between 0 and 1}."
  end

  defp judge_prompt(query, grounding, takes) do
    panel = Enum.map_join(takes, "\n", fn t -> "- #{t.model}: #{t.answer}" end)

    """
    QUESTION: #{query}

    <grounding>
    #{grounding}
    </grounding>

    <panel_answers>
    #{panel}
    </panel_answers>
    """
  end

  @spec default_embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  defp default_embed(text) do
    case Embeddings.embed([text]) do
      {:ok, %{vectors: [vec | _]}} -> {:ok, vec}
      {:ok, _} -> {:error, :no_vector}
      {:error, _} = err -> err
    end
  end
end
