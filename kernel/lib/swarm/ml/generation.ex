defmodule Swarm.ML.Generation do
  @moduledoc """
  Kernel↔Python boundary for text generation (the consilium panel + judge run on
  the local fleet). Like `Swarm.ML.Embeddings`, this is transport to the
  in-repo Intelligence pillar, not a model-provider plugin — `model` selects
  which fleet model the pillar calls over Ollama.
  """

  alias Swarm.LLM.Budget
  alias Swarm.ML.Boundary
  alias Swarm.Ml.V1.{GenerateRequest, Generator}

  @doc """
  Generate text from `model`. `opts`: `:system` (system prompt), `:json` (force
  strict JSON output). Returns `{:ok, text}` or a typed `{:error, reason}`.

  Budget backstop (T5, ADR-7): the system+prompt is checked against the hard
  per-call ceiling (`Swarm.Config.max_prompt_tokens/0`) **before** the gRPC
  ship-out, so NO caller — consilium or otherwise — can hand a raw payload to a
  model. Over-ceiling is refused `{:error, {:over_budget, estimated, ceiling}}`.
  """
  @spec generate(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(model, prompt, opts \\ []) when is_binary(model) and is_binary(prompt) do
    system = Keyword.get(opts, :system, "")

    case Budget.ensure(system <> prompt, Swarm.Config.max_prompt_tokens()) do
      {:error, _} = over ->
        over

      :ok ->
        cfg = Swarm.Config.ml_boundary()

        request = %GenerateRequest{
          model: model,
          prompt: prompt,
          system: system,
          json: Keyword.get(opts, :json, false)
        }

        Boundary.with_channel(cfg.address, &call(&1, request))
    end
  end

  @spec call(GRPC.Channel.t(), GenerateRequest.t()) :: {:ok, String.t()} | {:error, term()}
  defp call(channel, request) do
    # Generation on large models is slow; allow a generous deadline.
    case Generator.Stub.generate(channel, request, timeout: 300_000) do
      {:ok, resp} -> {:ok, resp.text}
      {:error, reason} -> {:error, {:rpc_failed, reason}}
    end
  end
end
