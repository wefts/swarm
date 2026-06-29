defmodule Swarm.Core.Server do
  @moduledoc """
  gRPC server for the Core API (Domain 11). Translates wire requests to
  `Swarm.Core` calls and back — no cognition here, just marshalling. An empty
  scope set from a channel defaults to a public-only context.
  """

  use GRPC.Server, service: Swarm.Core.V1.Core.Service

  alias Swarm.Core

  alias Swarm.Core.V1.{
    ActivityEvent,
    ActivityFeedResponse,
    AskResponse,
    Citation,
    DeliberationResponse,
    EdgeView,
    NamespaceStamp,
    NeighborhoodResponse,
    NodeView,
    PanelTake,
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
      # Set only when an escalation retained a deliberation for a non-anonymous
      # asker (ADR-15); empty otherwise. The channel keys the affordance on it.
      ask_ref: Map.get(a, :ask_ref, ""),
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

  @spec deliberation(Swarm.Core.V1.DeliberationRequest.t(), GRPC.Server.Stream.t()) ::
          DeliberationResponse.t()
  def deliberation(req, _stream) do
    case Core.deliberation(req.ask_ref, req.viewer, scopes(req.scopes)) do
      {:ok, d} ->
        %DeliberationResponse{
          status: :FOUND,
          ask_ref: d.ask_ref,
          answer: d.answer,
          confidence: d.confidence,
          disagreement: d.disagreement,
          panel: Enum.map(d.panel, &%PanelTake{model: &1.model, answer: &1.answer}),
          judge: d.judge,
          created_at: d.created_at
        }

      :not_found ->
        # Unknown/expired ask_ref, or the viewer is not the owner / scopes no longer
        # cover it — existence never revealed; only the status, no partial read.
        %DeliberationResponse{status: :NOT_FOUND}
    end
  end

  @spec neighborhood(Swarm.Core.V1.NeighborhoodRequest.t(), GRPC.Server.Stream.t()) ::
          NeighborhoodResponse.t()
  def neighborhood(req, _stream) do
    opts = [
      scopes: scopes(req.scopes),
      depth: req.depth,
      node_limit: req.node_limit,
      relation_types: req.relation_types
    ]

    case Core.neighborhood(req.node_id, opts) do
      {:ok, r} ->
        %NeighborhoodResponse{
          status: :FOUND,
          center_id: r.center_id,
          nodes:
            Enum.map(
              r.nodes,
              &%NodeView{
                id: &1.id,
                type: &1.type,
                key: &1.key,
                scope: &1.scope,
                confidence: &1.confidence,
                depth: &1.depth
              }
            ),
          edges:
            Enum.map(
              r.edges,
              &%EdgeView{
                src_id: &1.src_id,
                dst_id: &1.dst_id,
                relation: &1.relation,
                reliability: &1.reliability
              }
            ),
          truncated: r.truncated
        }

      {:error, :not_found} ->
        # Center not visible to the scopes (or absent) — existence never revealed;
        # an empty body, only the status (no partial read).
        %NeighborhoodResponse{status: :NOT_FOUND, center_id: req.node_id}
    end
  end

  @spec activity_feed(Swarm.Core.V1.ActivityFeedRequest.t(), GRPC.Server.Stream.t()) ::
          ActivityFeedResponse.t()
  def activity_feed(req, _stream) do
    page =
      Core.activity_feed(
        scopes: scopes(req.scopes),
        cursor: req.cursor,
        limit: req.limit,
        kinds: req.kinds
      )

    %ActivityFeedResponse{
      status: wire_status(page.status),
      next_cursor: page.next_cursor,
      events:
        Enum.map(
          page.events,
          &%ActivityEvent{
            kind: &1.kind,
            at: &1.at,
            subject_type: &1.subject_type,
            outcome: &1.outcome,
            count: &1.count
          }
        )
    }
  end

  defp scopes([]), do: ["public"]
  defp scopes(scopes), do: scopes
end
