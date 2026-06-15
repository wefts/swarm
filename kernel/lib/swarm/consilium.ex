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
  (`%{panel, judge}`, defaults to config), `:generator`/`:embedder` (injectable).
  """
  @spec deliberate(String.t(), keyword()) :: {:ok, verdict()} | {:error, term()}
  def deliberate(query, opts \\ []) when is_binary(query) do
    fleet = Keyword.get_lazy(opts, :fleet, &Swarm.Config.consilium/0)
    generator = Keyword.get(opts, :generator, &Generation.generate/3)
    embedder = Keyword.get(opts, :embedder, &default_embed/1)
    grounding = Keyword.get(opts, :grounding, "")

    case run_panel(fleet.panel, query, grounding, generator) do
      [] ->
        {:error, :panel_empty}

      takes ->
        disagreement = measure_disagreement(takes, embedder)

        case judge(fleet.judge, query, grounding, takes, generator) do
          {:ok, v} ->
            {:ok, Map.merge(v, %{disagreement: disagreement, panel: takes, judge: fleet.judge})}

          {:error, reason} ->
            Logger.error(
              "consilium judge failed: #{inspect(reason)}; quarantining (low confidence)"
            )

            {:error, {:judge_failed, reason}}
        end
    end
  end

  # Parallel panel — Task.async_stream, never an await-per-model loop.
  @spec run_panel([String.t()], String.t(), String.t(), fun()) :: [take()]
  defp run_panel(models, query, grounding, generator) do
    models
    |> Task.async_stream(
      fn model -> {model, generator.(model, panel_prompt(query, grounding), [])} end,
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

  @spec judge(String.t(), String.t(), String.t(), [take()], fun()) ::
          {:ok, %{answer: String.t(), confidence: float()}} | {:error, term()}
  defp judge(model, query, grounding, takes, generator) do
    do_judge(model, judge_prompt(query, grounding, takes), generator, @judge_attempts)
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
