defmodule Swarm.ML.Embeddings do
  @moduledoc """
  Kernel↔Python boundary for embeddings — the gRPC client that proves the
  cross-language contract end to end: send texts, get vectors back.

  This is the transport to the in-repo Intelligence pillar (the Python ML
  service), not a model-provider plugin. External providers implement
  `Swarm.Ports.Model` as adapters outside the kernel and may wrap this boundary.
  """

  alias Swarm.Graph.SchemaMeta
  alias Swarm.ML.Boundary
  alias Swarm.Ml.V1.{Embedder, EmbedRequest}

  @doc """
  Embed a batch of texts via the Python `Embed` RPC.

  Returns `{:ok, %{vectors: [[float()]], namespace: String.t(), dim: non_neg_integer()}}`
  or a typed `{:error, reason}`. Batch in, batch out — one round-trip per batch.
  """
  @spec embed([String.t()], keyword()) ::
          {:ok, %{vectors: [[float()]], namespace: String.t(), dim: non_neg_integer()}}
          | {:error, term()}
  def embed(texts, opts \\ []) when is_list(texts) do
    cfg = Swarm.Config.ml_boundary()
    namespace = Keyword.get(opts, :namespace, cfg.namespace)

    Boundary.with_channel(cfg.address, &call(&1, texts, namespace))
  end

  @spec call(GRPC.Channel.t(), [String.t()], String.t()) ::
          {:ok, map()} | {:error, term()}
  defp call(channel, texts, namespace) do
    request = %EmbedRequest{texts: texts, namespace: namespace}

    case Embedder.Stub.embed(channel, request) do
      {:ok, resp} ->
        # Stamp the embedding namespace on first use (ADR-6); idempotent.
        :ok = SchemaMeta.stamp(resp.namespace, resp.dim)

        {:ok,
         %{
           vectors: Enum.map(resp.vectors, & &1.values),
           namespace: resp.namespace,
           dim: resp.dim
         }}

      {:error, reason} ->
        {:error, {:rpc_failed, reason}}
    end
  end
end
