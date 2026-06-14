defmodule Swarm.Ports.Model do
  @moduledoc """
  Model port (Domain 4): an LLM / embedding provider, local or cloud.

  Behaviour only — concrete providers (Ollama, Claude, Gemini, …) are adapters
  outside the kernel. The in-repo Python ML service is reached through the
  `Swarm.ML.Embeddings` boundary, which a Model adapter can wrap.
  """

  @typedoc "A model request (prompt, params); shape fixed by the Protobuf contract."
  @type request :: map()

  @doc "Embed a batch of texts into vectors, stamped with an embedding namespace (ADR-6)."
  @callback embed(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [[float()]]} | {:error, term()}

  @doc "Run a completion / structured generation request."
  @callback complete(request()) :: {:ok, map()} | {:error, term()}

  @doc "Report provider identity, models, and cost tier."
  @callback describe() :: map()
end
