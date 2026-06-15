defmodule Swarm.Config do
  @moduledoc """
  Runtime config readers. Config is read at call time from the environment,
  never cached at import — secrets come from env, defaults match local infra.
  """

  @typedoc "Where the Python ML boundary lives and which embedding namespace to stamp."
  @type ml_boundary :: %{address: String.t(), namespace: String.t()}

  @doc "Address and default embedding namespace for the Python ML service."
  @spec ml_boundary() :: ml_boundary()
  def ml_boundary do
    %{
      address: env("SWARM_ML_ADDRESS", "127.0.0.1:50051"),
      namespace: env("SWARM_ML_NAMESPACE", "bge-m3")
    }
  end

  @typedoc "Consilium fleet: parallel panel models and the synthesizing judge."
  @type consilium :: %{panel: [String.t()], judge: String.t()}

  @doc "Consilium panel + judge model roster (Domain 4)."
  @spec consilium() :: consilium()
  def consilium do
    cfg = Application.get_env(:swarm, :consilium, [])
    %{panel: Keyword.fetch!(cfg, :panel), judge: Keyword.fetch!(cfg, :judge)}
  end

  @doc "Dimensionality of the stored embedding vectors (ADR-6)."
  @spec embedding_dim() :: pos_integer()
  def embedding_dim, do: Keyword.fetch!(Application.get_env(:swarm, :embedding, dim: 768), :dim)

  @doc "Per-day decay constant λ (ADR-3/ADR-9). Tuning inventory (ADR-8)."
  @spec decay_lambda() :: float()
  def decay_lambda, do: Keyword.fetch!(decay(), :lambda)

  @doc "Hill saturation constant S for f(seen_count) (ADR-9). Tuning inventory."
  @spec saturation_s() :: float()
  def saturation_s, do: Keyword.fetch!(decay(), :saturation_s)

  @spec decay() :: keyword()
  defp decay, do: Application.get_env(:swarm, :decay, lambda: 0.01, saturation_s: 2.0)

  @spec env(String.t(), String.t()) :: String.t()
  defp env(key, default), do: System.get_env(key) || default
end
