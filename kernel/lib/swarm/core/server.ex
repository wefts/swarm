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
    StatusResponse,
    TypeCount
  }

  @spec ask(Swarm.Core.V1.AskRequest.t(), GRPC.Server.Stream.t()) :: AskResponse.t()
  def ask(req, _stream) do
    a = Core.ask(req.query, scopes: scopes(req.scopes), viewer: req.viewer)

    %AskResponse{
      answer: a.answer,
      confidence: a.confidence,
      tier: a.tier,
      status: wire_status(a.status),
      citations:
        Enum.map(
          a.citations,
          &%Citation{source: &1.source, ref: &1.ref, confidence: &1.confidence}
        )
    }
  end

  # Core's result-algebra atom → the proto AnswerStatus enum (T6). Total over
  # `Swarm.Core.status()` — dialyzer enforces it, so a future 5th status fails the
  # build here (forcing a new clause) rather than silently mis-mapping on the wire.
  @spec wire_status(Swarm.Core.status()) :: atom()
  defp wire_status(:found), do: :FOUND
  defp wire_status(:not_found), do: :NOT_FOUND
  defp wire_status(:partial), do: :PARTIAL
  defp wire_status(:error), do: :ERROR

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
        ),
      inventory: Enum.map(s.inventory, &%TypeCount{type: &1.type, count: &1.count}),
      last_activity: s.last_activity,
      capabilities: s.capabilities
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
