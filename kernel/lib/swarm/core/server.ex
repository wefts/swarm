defmodule Swarm.Core.Server do
  @moduledoc """
  gRPC server for the Core API (Domain 11). Translates wire requests to
  `Swarm.Core` calls and back — no cognition here, just marshalling. An empty
  scope set from a channel defaults to a public-only context.
  """

  use GRPC.Server, service: Swarm.Core.V1.Core.Service

  alias Swarm.Core

  alias Swarm.Core.V1.{
    AskResponse,
    Citation,
    NamespaceStamp,
    SearchHit,
    SearchResponse,
    StatusResponse
  }

  @spec ask(Swarm.Core.V1.AskRequest.t(), GRPC.Server.Stream.t()) :: AskResponse.t()
  def ask(req, _stream) do
    a = Core.ask(req.query, scopes: scopes(req.scopes))

    %AskResponse{
      answer: a.answer,
      confidence: a.confidence,
      tier: a.tier,
      citations:
        Enum.map(
          a.citations,
          &%Citation{source: &1.source, ref: &1.ref, confidence: &1.confidence}
        )
    }
  end

  @spec kb_status(Swarm.Core.V1.StatusRequest.t(), GRPC.Server.Stream.t()) :: StatusResponse.t()
  def kb_status(_req, _stream) do
    s = Core.status()

    %StatusResponse{
      nodes: s.nodes,
      edges: s.edges,
      namespaces:
        Enum.map(
          s.namespaces,
          &%NamespaceStamp{
            namespace: &1.namespace,
            model: &1.model,
            dim: &1.dim,
            status: &1.status
          }
        )
    }
  end

  @spec kb_search(Swarm.Core.V1.SearchRequest.t(), GRPC.Server.Stream.t()) :: SearchResponse.t()
  def kb_search(req, _stream) do
    limit = if req.limit == 0, do: 10, else: req.limit
    hits = Core.search(req.query, scopes(req.scopes), limit: limit)

    %SearchResponse{
      hits: Enum.map(hits, &%SearchHit{id: &1.id, type: &1.type, key: &1.key, score: &1.score})
    }
  end

  defp scopes([]), do: ["public"]
  defp scopes(scopes), do: scopes
end
