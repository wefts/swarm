defmodule Swarm.ML.Generation do
  @moduledoc """
  Kernel↔Python boundary for text generation (the consilium panel + judge run on
  the local fleet). Like `Swarm.ML.Embeddings`, this is transport to the
  in-repo Intelligence pillar, not a model-provider plugin — `model` selects
  which fleet model the pillar calls over Ollama.
  """

  alias Swarm.Ml.V1.{GenerateRequest, Generator}

  @doc """
  Generate text from `model`. `opts`: `:system` (system prompt), `:json` (force
  strict JSON output). Returns `{:ok, text}` or a typed `{:error, reason}`.
  """
  @spec generate(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(model, prompt, opts \\ []) when is_binary(model) and is_binary(prompt) do
    cfg = Swarm.Config.ml_boundary()

    request = %GenerateRequest{
      model: model,
      prompt: prompt,
      system: Keyword.get(opts, :system, ""),
      json: Keyword.get(opts, :json, false)
    }

    case GRPC.Stub.connect(cfg.address) do
      {:ok, channel} ->
        try do
          call(channel, request)
        after
          GRPC.Stub.disconnect(channel)
        end

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
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
