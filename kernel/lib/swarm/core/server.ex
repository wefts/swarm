defmodule Swarm.Core.Server do
  @moduledoc """
  gRPC server for the Core API (Domain 11). Translates wire requests to
  `Swarm.Core` calls and back — no cognition here, just marshalling. An empty
  scope set from a channel defaults to a public-only context.
  """

  use GRPC.Server, service: Swarm.Core.V1.Core.Service

  alias Swarm.{Admin, Conversations, Core}
  alias Swarm.Core.Auth

  alias Swarm.Core.V1.{
    ActivityEvent,
    ActivityFeedResponse,
    AdminActionResponse,
    AskResponse,
    Citation,
    ConversationView,
    DeliberationResponse,
    EdgeView,
    GetConversationResponse,
    ListConversationsResponse,
    LogConversationResponse,
    MessageView,
    NamespaceStamp,
    NeighborhoodResponse,
    NodeView,
    PanelTake,
    ResolveActorResponse,
    SearchHit,
    SearchResponse,
    StatusResponse,
    TypeCount
  }

  @spec ask(Swarm.Core.V1.AskRequest.t(), GRPC.Server.Stream.t()) :: AskResponse.t()
  def ask(req, _stream) do
    {viewer, scopes} = ctx(req.viewer, req.scopes)

    a =
      Core.ask(req.query,
        scopes: scopes,
        viewer: viewer,
        active_keys: req.active_keys,
        conversation_id: nz(req.conversation_id)
      )

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
    # SearchRequest now carries an optional signed `assertion` (ADR-16): dual-accept —
    # derive scopes when signed, else use the wire scopes (legacy). KbStatus stays
    # global (no scope filtering), so it needs none.
    {_viewer, scopes} = ctx(req.assertion, req.scopes)
    limit = if req.limit == 0, do: 10, else: req.limit
    hits = Core.search(req.query, scopes, limit: limit)

    %SearchResponse{
      hits: Enum.map(hits, &%SearchHit{id: &1.id, type: &1.type, key: &1.key, score: &1.score})
    }
  end

  @spec deliberation(Swarm.Core.V1.DeliberationRequest.t(), GRPC.Server.Stream.t()) ::
          DeliberationResponse.t()
  def deliberation(req, _stream) do
    {viewer, scopes} = ctx(req.viewer, req.scopes)

    case Core.deliberation(req.ask_ref, viewer, scopes) do
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
    {_viewer, scopes} = ctx(req.viewer, req.scopes)

    opts = [
      scopes: scopes,
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
    {_viewer, scopes} = ctx(req.viewer, req.scopes)

    page =
      Core.activity_feed(
        scopes: scopes,
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

  # --- Identity / privacy RPCs (ADR-16, step 6a) — always strict ------------

  @spec resolve_actor(Swarm.Core.V1.ResolveActorRequest.t(), GRPC.Server.Stream.t()) ::
          ResolveActorResponse.t()
  def resolve_actor(req, _stream) do
    case Auth.actor(req.assertion) do
      {:ok, a} ->
        %ResolveActorResponse{
          status: :CALL_OK,
          uuid: a.uuid,
          scopes: a.scopes,
          caps: a.caps,
          login: a.login
        }

      {:error, _} ->
        %ResolveActorResponse{status: :CALL_UNAUTHENTICATED}
    end
  end

  @spec provision_actor(Swarm.Core.V1.ProvisionActorRequest.t(), GRPC.Server.Stream.t()) ::
          ResolveActorResponse.t()
  def provision_actor(req, _stream) do
    # ADR-16 D3 over the wire: the whole claim set is INSIDE the signed provision
    # token (aud swarm.provision.v1) — verify, then run the guarded JIT path.
    # :inactive (resurrect attempt) collapses to UNAUTHENTICATED like every other
    # actor failure (no disabled-account oracle); a taken login is a caller error.
    with {:ok, claims} <- Swarm.Actor.verify_provision(req.provision),
         {:ok, user} <- Swarm.Identity.provision_from_claims(claims) do
      %ResolveActorResponse{
        status: :CALL_OK,
        uuid: user.id,
        login: user.login,
        scopes: Swarm.Identity.scopes_for(user.id),
        caps: Swarm.Identity.caps_for(user.id)
      }
    else
      {:error, :login_taken} -> %ResolveActorResponse{status: :CALL_BAD_REQUEST}
      {:error, _} -> %ResolveActorResponse{status: :CALL_UNAUTHENTICATED}
    end
  end

  @spec log_conversation(Swarm.Core.V1.LogConversationRequest.t(), GRPC.Server.Stream.t()) ::
          LogConversationResponse.t()
  def log_conversation(req, _stream) do
    with_actor(req.assertion, %LogConversationResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      # Validate the message role at the boundary (else the DB CHECK would 500 — and
      # for a new conversation would leave an empty conversation behind). Council.
      if req.role in ["user", "assistant"] do
        attrs = %{
          role: req.role,
          body: req.body,
          ask_ref: nz(req.ask_ref),
          author_user_id: a.uuid
        }

        log_turn(a.uuid, req.conversation_id, req.title, attrs)
      else
        %LogConversationResponse{status: :CALL_BAD_REQUEST}
      end
    end)
  end

  # Empty conversation_id ⇒ create then append the first turn; else append to the
  # owner's existing conversation (NOT_FOUND if it is not theirs).
  @spec log_turn(String.t(), String.t(), String.t(), map()) :: LogConversationResponse.t()
  defp log_turn(owner, "", title, attrs) do
    {:ok, conv} = Conversations.create(owner, %{title: nz(title)})
    {:ok, msg} = Conversations.add_message(owner, conv.id, attrs)
    %LogConversationResponse{status: :CALL_OK, conversation_id: conv.id, message_id: msg.id}
  end

  defp log_turn(owner, conversation_id, _title, attrs) do
    case Conversations.add_message(owner, conversation_id, attrs) do
      {:ok, msg} ->
        %LogConversationResponse{
          status: :CALL_OK,
          conversation_id: conversation_id,
          message_id: msg.id
        }

      :not_found ->
        %LogConversationResponse{status: :CALL_NOT_FOUND}
    end
  end

  @spec list_conversations(Swarm.Core.V1.ListConversationsRequest.t(), GRPC.Server.Stream.t()) ::
          ListConversationsResponse.t()
  def list_conversations(req, _stream) do
    with_actor(req.assertion, %ListConversationsResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      %ListConversationsResponse{
        status: :CALL_OK,
        conversations: Enum.map(Conversations.list(a.uuid), &conv_view/1)
      }
    end)
  end

  @spec get_conversation(Swarm.Core.V1.GetConversationRequest.t(), GRPC.Server.Stream.t()) ::
          GetConversationResponse.t()
  def get_conversation(req, _stream) do
    with_actor(req.assertion, %GetConversationResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      conversation_response(Conversations.get(a.uuid, req.conversation_id))
    end)
  end

  @spec admin_read_conversation(
          Swarm.Core.V1.AdminReadConversationRequest.t(),
          GRPC.Server.Stream.t()
        ) :: GetConversationResponse.t()
  def admin_read_conversation(req, _stream) do
    with_actor(req.assertion, %GetConversationResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      # Break-glass is reason-required (ADR-16 D6 accountability): an empty reason is a
      # bad request, not an unlogged read.
      case nz(req.reason) do
        nil ->
          %GetConversationResponse{status: :CALL_BAD_REQUEST}

        reason ->
          conversation_response(Conversations.admin_read(a.uuid, req.conversation_id, reason))
      end
    end)
  end

  @spec manage_access(Swarm.Core.V1.ManageAccessRequest.t(), GRPC.Server.Stream.t()) ::
          AdminActionResponse.t()
  def manage_access(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      manage_access_op(a.uuid, req)
    end)
  end

  @spec manage_access_op(String.t(), Swarm.Core.V1.ManageAccessRequest.t()) ::
          AdminActionResponse.t()
  defp manage_access_op(actor_id, %{op: op, role: role} = req)
       when op in [:GRANT_ROLE, :REVOKE_ROLE] do
    # Validate the role vocab at the boundary (else the DB CHECK would 500). Council.
    cond do
      role not in ["admin", "superadmin"] ->
        %AdminActionResponse{status: :CALL_BAD_REQUEST}

      op == :GRANT_ROLE ->
        action_response(guarded_target(req.target_user_id, &Admin.grant_role(actor_id, &1, role)))

      true ->
        action_response(
          guarded_target(req.target_user_id, &Admin.revoke_role(actor_id, &1, role))
        )
    end
  end

  defp manage_access_op(actor_id, %{op: :GRANT_GROUP} = req),
    do:
      action_response(
        guarded_target(req.target_user_id, &Admin.grant_group(actor_id, &1, req.group_id))
      )

  defp manage_access_op(actor_id, %{op: :REVOKE_GROUP} = req),
    do:
      action_response(
        guarded_target(req.target_user_id, &Admin.revoke_group(actor_id, &1, req.group_id))
      )

  defp manage_access_op(actor_id, %{op: :SET_GROUP_SCOPES} = req),
    do: action_response(Admin.set_group_scopes(actor_id, req.group_id, req.scopes))

  defp manage_access_op(_actor_id, _req), do: %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}

  @spec manage_user(Swarm.Core.V1.ManageUserRequest.t(), GRPC.Server.Stream.t()) ::
          AdminActionResponse.t()
  def manage_user(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case req.op do
        :INVITE ->
          do_invite(a.uuid, req)

        :DEACTIVATE ->
          action_response(guarded_target(req.target_user_id, &Admin.deactivate_user(a.uuid, &1)))

        :DELETE ->
          action_response(guarded_target(req.target_user_id, &Admin.delete_user(a.uuid, &1)))

        _ ->
          %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec do_invite(String.t(), Swarm.Core.V1.ManageUserRequest.t()) :: AdminActionResponse.t()
  defp do_invite(actor_id, req) do
    # Validate login at the boundary (else the app_user unique/NOT-NULL constraints
    # would 500): non-empty, and not already taken. The pre-check leaves a tiny TOCTOU
    # race that the unique index backstops (admin ops are low-concurrency). Council.
    cond do
      nz(req.login) == nil -> %AdminActionResponse{status: :CALL_BAD_REQUEST}
      Swarm.Identity.by_login(req.login) != nil -> %AdminActionResponse{status: :CALL_BAD_REQUEST}
      true -> do_invite_ok(actor_id, req)
    end
  end

  @spec do_invite_ok(String.t(), Swarm.Core.V1.ManageUserRequest.t()) :: AdminActionResponse.t()
  defp do_invite_ok(actor_id, req) do
    case Admin.invite_user(actor_id, %{
           login: req.login,
           first_name: nz(req.first_name),
           last_name: nz(req.last_name),
           nickname: nz(req.nickname)
         }) do
      {:ok, u} -> %AdminActionResponse{status: :CALL_OK, user_id: u.id}
      :not_authorized -> %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}
    end
  end

  # --- helpers --------------------------------------------------------------

  # Legacy-RPC context: dual-accept (verify a signed viewer, else trust plaintext).
  # `:unauthenticated` (strict mode, no assertion) ⇒ anonymous public — fail closed.
  @spec ctx(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  defp ctx(viewer, wire_scopes) do
    case Auth.legacy_context(viewer, wire_scopes) do
      {:ok, c} -> {c.viewer, c.scopes}
      {:error, :unauthenticated} -> {"", ["public"]}
    end
  end

  # Strict actor resolution for the identity/privacy RPCs; runs `fun` with the
  # verified actor, or returns the given UNAUTHENTICATED response.
  @spec with_actor(String.t(), resp, (Swarm.Actor.actor() -> resp)) :: resp when resp: struct()
  defp with_actor(assertion, unauth, fun) do
    case Auth.actor(assertion) do
      {:ok, a} -> fun.(a)
      {:error, _} -> unauth
    end
  end

  # A client-supplied target uuid is validated before it reaches the store (no
  # cast-error 500). Malformed ⇒ `:not_authorized` (fail closed, no oracle).
  @spec guarded_target(String.t(), (String.t() -> :ok | :not_authorized)) :: :ok | :not_authorized
  defp guarded_target(target_id, fun) do
    case Ecto.UUID.cast(target_id) do
      {:ok, _} -> fun.(target_id)
      :error -> :not_authorized
    end
  end

  @spec conversation_response(
          {:ok, %{conversation: map(), messages: [map()]}}
          | :not_found
          | :not_authorized
        ) :: GetConversationResponse.t()
  defp conversation_response({:ok, %{conversation: c, messages: m}}),
    do: %GetConversationResponse{
      status: :CALL_OK,
      conversation: conv_view(c),
      messages: Enum.map(m, &msg_view/1)
    }

  defp conversation_response(:not_authorized),
    do: %GetConversationResponse{status: :CALL_NOT_AUTHORIZED}

  defp conversation_response(:not_found), do: %GetConversationResponse{status: :CALL_NOT_FOUND}

  @spec action_response(:ok | :not_authorized | {:error, :ungrantable_scope}) ::
          AdminActionResponse.t()
  defp action_response(:ok), do: %AdminActionResponse{status: :CALL_OK}
  defp action_response(:not_authorized), do: %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}

  # A grant of an ungrantable scope (private / out-of-vocabulary) is a caller
  # error, not an authz outcome (person-scope-leak-guard).
  defp action_response({:error, :ungrantable_scope}),
    do: %AdminActionResponse{status: :CALL_BAD_REQUEST}

  @spec conv_view(map()) :: ConversationView.t()
  defp conv_view(c) do
    %ConversationView{
      id: c.id,
      owner_id: c.owner_id,
      scope: c.scope || "",
      title: c.title || "",
      created_at: iso(c.created_at),
      updated_at: iso(c.updated_at)
    }
  end

  @spec msg_view(map()) :: MessageView.t()
  defp msg_view(m) do
    %MessageView{
      id: m.id,
      role: m.role,
      body: m.body,
      author_user_id: m.author_user_id || "",
      ask_ref: m.ask_ref || "",
      created_at: iso(m.created_at)
    }
  end

  @spec nz(String.t()) :: String.t() | nil
  defp nz(""), do: nil
  defp nz(s), do: s

  @spec iso(term()) :: String.t()
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso(other), do: to_string(other)
end
