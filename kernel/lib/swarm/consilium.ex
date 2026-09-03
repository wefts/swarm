defmodule Swarm.Consilium do
  @moduledoc """
  The escalation top (Domain 4). When the gate escalates, the mid-tier panel
  answers **in parallel**, inter-model disagreement is measured **before**
  synthesis (a confidence signal, not noise), and a stronger, different-family
  judge synthesizes one grounded verdict.

  Fail-loud (ADR-7 / Domain 4): a judge failure returns a typed
  `{:error, {:judge_failed, _}}` — never raw, unsynthesized panel text. The
  configured judge must not also be a panel model: ADR-11's external-reward rule
  applies at the model-fleet level too, because a model cannot reliably catch the
  same contrastive inversion it just produced. Judge accuracy on synthesized
  answers is measured separately from the easier structured entailment gate.

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
          supported: boolean(),
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

    with :ok <- validate_fleet(fleet),
         :ok <- budget(panel_prompt, ceiling),
         [_ | _] = takes <- run_panel(fleet.panel, panel_prompt, generator) do
      # Disagreement depends ONLY on the panel answers, not the judge — so embed it
      # CONCURRENTLY with the judge instead of serially after (ADR-17 #1, consilium-latency
      # council). The task body is rescue-guarded (never abnormally exits → linking is
      # safe); every exit path yields-or-shuts-it-down (no orphan, no mailbox pollution, no
      # crash on a slow embed — codex review).
      dis_task = Task.async(fn -> safe_disagreement(takes, embedder) end)

      judge_and_assemble(
        query,
        grounding,
        takes,
        fleet,
        generator,
        ceiling,
        panel_prompt,
        dis_task
      )
    else
      {:error, {:self_judging, _}} = err -> err
      {:error, {:over_budget, est, ceil}} -> over_budget(est, ceil)
      [] -> {:error, :panel_empty}
    end
  end

  # The judge stage + final assembly. Owns the disagreement task's lifecycle: shut it down
  # on any judge-path error, harvest it (yield-or-kill, fall back to 0.0) on success.
  @spec judge_and_assemble(
          String.t(),
          String.t(),
          [take()],
          map(),
          fun(),
          pos_integer(),
          String.t(),
          Task.t()
        ) :: {:ok, verdict()} | {:error, term()}
  defp judge_and_assemble(
         query,
         grounding,
         takes,
         fleet,
         generator,
         ceiling,
         panel_prompt,
         dis_task
       ) do
    judge_prompt = judge_prompt(query, grounding, takes)

    with :ok <- budget(judge_prompt, ceiling),
         {:ok, v} <- judge(fleet.judge, judge_prompt, generator) do
      account_escalation(fleet.panel, panel_prompt, takes, judge_prompt, v.answer)
      disagreement = harvest_disagreement(dis_task)
      {:ok, Map.merge(v, %{disagreement: disagreement, panel: takes, judge: fleet.judge})}
    else
      {:error, {:over_budget, est, ceil}} ->
        Task.shutdown(dis_task, :brutal_kill)
        over_budget(est, ceil)

      {:error, reason} ->
        Task.shutdown(dis_task, :brutal_kill)
        Logger.error("consilium judge failed: #{inspect(reason)}; quarantining (low confidence)")
        {:error, {:judge_failed, reason}}
    end
  end

  @spec over_budget(non_neg_integer(), pos_integer()) :: {:error, Budget.over_budget()}
  defp over_budget(est, ceil) do
    Logger.warning("consilium: escalation refused — over budget (#{est} > #{ceil} tokens)")
    Budget.account(est, 0, %{outcome: :over_budget})
    {:error, {:over_budget, est, ceil}}
  end

  # Disagreement is a best-effort signal — a slow/failed embed must never crash the escalation
  # after the judge already succeeded. Yield within the budget, else kill and degrade to 0.0.
  @spec harvest_disagreement(Task.t()) :: float()
  defp harvest_disagreement(task) do
    case Task.yield(task, @panel_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, disagreement} -> disagreement
      _ -> 0.0
    end
  end

  # measure_disagreement is already error-safe on embed failures; this belt guarantees the
  # concurrent TASK never abnormally exits (so the linked caller can't be taken down).
  @spec safe_disagreement([take()], fun()) :: float()
  defp safe_disagreement(takes, embedder) do
    measure_disagreement(takes, embedder)
  rescue
    _ -> 0.0
  end

  @doc """
  Run ONLY the judge stage on already-gathered panel `takes`: build the judge prompt,
  budget-check it, run the judge, parse the verdict. A public seam for the
  `supported`-calibration eval (`Swarm.Consilium.Calibration`) and the future adaptive
  thin-judge — so both exercise the EXACT judge prompt + parse the live path uses. `opts`:
  `:fleet`, `:generator`, `:token_ceiling`.
  """
  @spec judge_verdict(String.t(), String.t(), [take()], keyword()) ::
          {:ok, %{answer: String.t(), confidence: float(), supported: boolean()}}
          | {:error, term()}
  def judge_verdict(query, grounding, takes, opts \\ []) do
    fleet = Keyword.get_lazy(opts, :fleet, &Swarm.Config.consilium/0)
    generator = Keyword.get(opts, :generator, &Generation.generate/3)
    ceiling = Keyword.get(opts, :token_ceiling, Map.get(fleet, :token_ceiling, 32_000))
    judge_prompt = judge_prompt(query, grounding, takes)

    with :ok <- validate_fleet(fleet),
         :ok <- budget(judge_prompt, ceiling) do
      judge(fleet.judge, judge_prompt, generator)
    end
  end

  @spec validate_fleet(map()) :: :ok | {:error, {:self_judging, String.t()}}
  defp validate_fleet(%{panel: panel, judge: judge}) when is_list(panel) and is_binary(judge) do
    if judge in panel do
      Logger.error(
        "consilium fleet rejected: judge #{inspect(judge)} is also a panel model " <>
          "(ADR-11 forbids self-judging synthesized answers)"
      )

      {:error, {:self_judging, judge}}
    else
      :ok
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
          {:ok, %{answer: String.t(), confidence: float(), supported: boolean()}}
          | {:error, term()}
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
          {:ok, %{answer: String.t(), confidence: float(), supported: boolean()}}
          | {:error, term()}
  defp parse_verdict(raw) do
    case Jason.decode(raw) do
      {:ok, %{"answer" => a, "confidence" => c} = m} when is_binary(a) and is_number(c) ->
        {:ok, %{answer: a, confidence: c / 1, supported: parse_supported(m)}}

      {:ok, _} ->
        {:error, :invalid_verdict_schema}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  # Groundedness self-flag (the calibration anchor): true ONLY when the judge marks
  # the answer fully supported by the grounding. FAIL-CLOSED — anything other than an
  # explicit `true` (absent, null, non-boolean) is treated as NOT supported, so a
  # schema hiccup can never re-admit the over-confident-ungrounded answer (council:
  # codex + gemini both flagged fail-open as the fatal mistake).
  @spec parse_supported(map()) :: boolean()
  defp parse_supported(%{"supported" => s}) when is_boolean(s), do: s
  defp parse_supported(_), do: false

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
    ~s|You are a strict synthesis judge. Combine the panel answers into ONE answer | <>
      ~s|that the grounding SUPPORTS; drop any claim the grounding does not support, and | <>
      ~s|if a panel answer contradicts the grounding, correct it to the grounded value. | <>
      ~s|Set "supported" to true ONLY if the grounding directly and unambiguously answers | <>
      ~s|the EXACT question asked. Set it to false if: the grounding does not address the | <>
      ~s|question, answers only a different/partial case than asked, or gives CONFLICTING | <>
      ~s|answers with no way to resolve which is correct. Never guess from outside the | <>
      ~s|grounding. Respond as strict JSON only: {"answer": string, "confidence": number | <>
      ~s|between 0 and 1, "supported": boolean}.|
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
