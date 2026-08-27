defmodule Swarm.Core.Server do
  @moduledoc """
  gRPC server for the Core API (Domain 11). Translates wire requests to
  `Swarm.Core` calls and back — no cognition here, just marshalling. An empty
  scope set from a channel defaults to a public-only context.

  Identity/admin RPCs pass the verified actor as `{uuid, sid}` (ADR-20): capabilities are
  derived for THIS session, so a superadmin elevation is bound to the session that
  requested it.
  """

  use GRPC.Server, service: Swarm.Core.V1.Core.Service

  alias Swarm.{Admin, Conversations, Core, Elevation}
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
    ElevateRequest,
    ElevateResponse,
    EndElevationRequest,
    GetConversationResponse,
    GetGroupRequest,
    GetGroupResponse,
    GetProjectRequest,
    GetProjectResponse,
    GetUserRequest,
    GetUserResponse,
    GroupMember,
    GroupView,
    ListConversationsResponse,
    ListGroupsRequest,
    ListGroupsResponse,
    ListProjectsRequest,
    ListProjectsResponse,
    ListRolesRequest,
    ListRolesResponse,
    ListSsoMapRequest,
    ListSsoMapResponse,
    LogConversationResponse,
    ManageGroupRequest,
    ManageProjectRequest,
    ManageSsoMapRequest,
    MessageView,
    NamespaceStamp,
    NeighborhoodResponse,
    NodeView,
    PanelTake,
    ProjectMemberView,
    ProjectView,
    ResolveActorResponse,
    RoleView,
    SearchHit,
    SearchResponse,
    SourceView,
    SsoMapView,
    StatusResponse,
    TypeCount
  }

  @spec ask(Swarm.Core.V1.AskRequest.t(), GRPC.Server.Stream.t()) :: AskResponse.t()
  def ask(req, _stream) do
    {viewer, scopes, verified?} = ctx(req.viewer, req.scopes)

    a =
      Core.ask(req.query,
        scopes: scopes,
        viewer: viewer,
        verified: verified?,
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
    # SearchRequest carries an optional signed `assertion` (ADR-16): dual-accept —
    # derive scopes when signed, else use the wire scopes (legacy). KbStatus stays
    # global (no scope filtering), so it needs none.
    {_viewer, scopes, _verified} = ctx(req.assertion, req.scopes)
    limit = if req.limit == 0, do: 10, else: req.limit
    hits = Core.search(req.query, scopes, limit: limit)

    %SearchResponse{
      hits: Enum.map(hits, &%SearchHit{id: &1.id, type: &1.type, key: &1.key, score: &1.score})
    }
  end

  @spec deliberation(Swarm.Core.V1.DeliberationRequest.t(), GRPC.Server.Stream.t()) ::
          DeliberationResponse.t()
  def deliberation(req, _stream) do
    {viewer, scopes, _verified} = ctx(req.viewer, req.scopes)

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
    {_viewer, scopes, _verified} = ctx(req.viewer, req.scopes)

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
    {_viewer, scopes, _verified} = ctx(req.viewer, req.scopes)

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
          login: a.login,
          elevation_expires_at: iso_or_empty(a.elevation_expires_at),
          external: a.external
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
        # A provision token carries no session ⇒ never elevated caps here.
        caps: Swarm.Identity.caps_for(user.id),
        external: user.external
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
      # bad request, not an unlogged read. `read_any_conversation` exists only under a
      # live, session-bound elevation (ADR-20) — hence the {uuid, sid} actor ref.
      case nz(req.reason) do
        nil ->
          %GetConversationResponse{status: :CALL_BAD_REQUEST}

        reason ->
          conversation_response(
            Conversations.admin_read(actor_ref(a), req.conversation_id, reason)
          )
      end
    end)
  end

  @spec list_users(Swarm.Core.V1.ListUsersRequest.t(), GRPC.Server.Stream.t()) ::
          Swarm.Core.V1.ListUsersResponse.t()
  def list_users(req, _stream) do
    alias Swarm.Core.V1.ListUsersResponse

    with_actor(req.assertion, %ListUsersResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Admin.list_users(actor_ref(a),
             include_deleted: req.include_deleted,
             limit: req.limit,
             query: req.query,
             offset: req.offset
           ) do
        {:ok, {users, total}} ->
          %ListUsersResponse{
            status: :CALL_OK,
            users: Enum.map(users, &to_user_view/1),
            total: total
          }

        :not_authorized ->
          %ListUsersResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec get_user(GetUserRequest.t(), GRPC.Server.Stream.t()) :: GetUserResponse.t()
  def get_user(req, _stream) do
    with_actor(req.assertion, %GetUserResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Admin.get_user(actor_ref(a), req.user_id) do
        {:ok, v} ->
          %GetUserResponse{
            status: :CALL_OK,
            user: to_user_view(v, emails: v.emails, projects: v.projects)
          }

        :not_found ->
          %GetUserResponse{status: :CALL_NOT_FOUND}

        :not_authorized ->
          %GetUserResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec list_groups(ListGroupsRequest.t(), GRPC.Server.Stream.t()) :: ListGroupsResponse.t()
  def list_groups(req, _stream) do
    with_actor(req.assertion, %ListGroupsResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Admin.list_groups(actor_ref(a)) do
        {:ok, groups} ->
          %ListGroupsResponse{
            status: :CALL_OK,
            groups: Enum.map(groups, &to_group_view/1)
          }

        :not_authorized ->
          %ListGroupsResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec list_roles(ListRolesRequest.t(), GRPC.Server.Stream.t()) :: ListRolesResponse.t()
  def list_roles(req, _stream) do
    with_actor(req.assertion, %ListRolesResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Admin.list_roles(actor_ref(a)) do
        {:ok, roles} ->
          %ListRolesResponse{
            status: :CALL_OK,
            roles: Enum.map(roles, &to_role_view/1)
          }

        :not_authorized ->
          %ListRolesResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec get_group(GetGroupRequest.t(), GRPC.Server.Stream.t()) :: GetGroupResponse.t()
  def get_group(req, _stream) do
    with_actor(req.assertion, %GetGroupResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Admin.get_group(actor_ref(a), req.group_id) do
        {:ok, %{group: g, members: members}} ->
          %GetGroupResponse{
            status: :CALL_OK,
            group: to_group_view(g),
            members: Enum.map(members, &to_group_member/1)
          }

        :not_found ->
          %GetGroupResponse{status: :CALL_NOT_FOUND}

        :not_authorized ->
          %GetGroupResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec to_group_member(map()) :: GroupMember.t()
  defp to_group_member(m) do
    %GroupMember{
      user_id: m.user_id,
      login: m.login,
      providers: m.providers,
      status: m.status
    }
  end

  @spec to_group_view(map()) :: GroupView.t()
  defp to_group_view(view) do
    %GroupView{
      id: view.id,
      member_count: view.member_count,
      granted_roles: view.granted_roles,
      name: view.name || "",
      description: view.description || ""
    }
  end

  @spec to_role_view(map()) :: RoleView.t()
  defp to_role_view(view) do
    %RoleView{
      name: view.name,
      capabilities: view.capabilities,
      holder_count: view.holder_count
    }
  end

  @spec to_user_view(map(), keyword()) :: Swarm.Core.V1.UserView.t()
  defp to_user_view(view, opts \\ []) do
    %Swarm.Core.V1.UserView{
      id: view.id,
      login: view.login,
      first_name: view.first_name || "",
      last_name: view.last_name || "",
      nickname: view.nickname || "",
      status: view.status,
      roles: view.roles,
      groups: view.groups,
      providers: view.providers,
      last_login_at: iso(view.last_login_at),
      emails: opts[:emails] || [],
      external: Map.get(view, :external, false),
      projects: opts[:projects] || []
    }
  end

  @spec manage_access(Swarm.Core.V1.ManageAccessRequest.t(), GRPC.Server.Stream.t()) ::
          AdminActionResponse.t()
  def manage_access(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      manage_access_op(actor_ref(a), req)
    end)
  end

  @spec manage_access_op(Swarm.Identity.actor_ref(), Swarm.Core.V1.ManageAccessRequest.t()) ::
          AdminActionResponse.t()
  # ADR-19/20: per-user role grants are forbidden (roles hang on groups). Admin audits
  # the denial and returns {:error, :role_on_user_forbidden} → BAD_REQUEST.
  defp manage_access_op(actor, %{op: :GRANT_ROLE} = req),
    do: action_response(Admin.grant_role(actor, req.target_user_id, req.role))

  defp manage_access_op(actor, %{op: :REVOKE_ROLE} = req),
    do: action_response(Admin.revoke_role(actor, req.target_user_id, req.role))

  defp manage_access_op(actor, %{op: :GRANT_GROUP} = req),
    do:
      action_response(
        guarded_target(req.target_user_id, &Admin.grant_group(actor, &1, req.group_id))
      )

  defp manage_access_op(actor, %{op: :REVOKE_GROUP} = req),
    do:
      action_response(
        guarded_target(req.target_user_id, &Admin.revoke_group(actor, &1, req.group_id))
      )

  # ADR-20 D3: groups never grant source visibility — rejected + audited.
  defp manage_access_op(actor, %{op: :SET_GROUP_SCOPES} = req),
    do: action_response(Admin.set_group_scopes(actor, req.group_id, req.scopes))

  defp manage_access_op(_actor, _req), do: %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}

  @spec manage_group(ManageGroupRequest.t(), GRPC.Server.Stream.t()) :: AdminActionResponse.t()
  def manage_group(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      manage_group_op(actor_ref(a), req)
    end)
  end

  @spec manage_group_op(Swarm.Identity.actor_ref(), ManageGroupRequest.t()) ::
          AdminActionResponse.t()
  # The group set is fixed (ADR-20 D7): lifecycle ops are rejected + audited.
  defp manage_group_op(actor, %{op: :GROUP_CREATE} = req),
    do:
      action_response(Admin.create_group(actor, req.group_id, nz(req.name), nz(req.description)))

  defp manage_group_op(actor, %{op: :GROUP_RENAME} = req),
    do: action_response(Admin.rename_group(actor, req.group_id, nz(req.name)))

  defp manage_group_op(actor, %{op: :GROUP_DELETE} = req),
    do: action_response(Admin.delete_group(actor, req.group_id, req.confirm))

  # Role probes (incl. a `superadmin` bind attempt) go THROUGH Admin so the denial is audited;
  # Admin answers {:error, :invalid_role} → BAD_REQUEST for anything but `admin` (ADR-20 D9).
  defp manage_group_op(actor, %{op: :GROUP_SET_ROLE} = req),
    do:
      action_response(guarded_group_id(req.group_id, &Admin.set_group_role(actor, &1, req.role)))

  defp manage_group_op(actor, %{op: :GROUP_CLEAR_ROLE} = req),
    do:
      action_response(
        guarded_group_id(req.group_id, &Admin.clear_group_role(actor, &1, req.role))
      )

  defp manage_group_op(actor, %{op: :GROUP_SET_SCOPES} = req),
    do: action_response(Admin.set_group_scopes(actor, req.group_id, req.scopes))

  defp manage_group_op(_actor, _req), do: %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}

  @spec list_sso_map(ListSsoMapRequest.t(), GRPC.Server.Stream.t()) :: ListSsoMapResponse.t()
  def list_sso_map(req, _stream) do
    with_actor(req.assertion, %ListSsoMapResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Admin.list_sso_map(actor_ref(a)) do
        {:ok, mappings} ->
          %ListSsoMapResponse{status: :CALL_OK, mappings: Enum.map(mappings, &to_sso_map_view/1)}

        :not_authorized ->
          %ListSsoMapResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec to_sso_map_view(map()) :: SsoMapView.t()
  defp to_sso_map_view(m) do
    %SsoMapView{
      provider: m.provider,
      incoming_group: m.incoming_group,
      our_group_id: m.our_group_id
    }
  end

  @spec manage_sso_map(ManageSsoMapRequest.t(), GRPC.Server.Stream.t()) :: AdminActionResponse.t()
  def manage_sso_map(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      manage_sso_map_op(actor_ref(a), req)
    end)
  end

  @spec manage_sso_map_op(Swarm.Identity.actor_ref(), ManageSsoMapRequest.t()) ::
          AdminActionResponse.t()
  defp manage_sso_map_op(actor, %{op: :SSO_MAP_PUT} = req) do
    case {nz(req.provider), nz(req.incoming_group), nz(req.our_group_id)} do
      {provider, incoming, our_group}
      when is_binary(provider) and is_binary(incoming) and is_binary(our_group) ->
        action_response(Admin.put_sso_map(actor, provider, incoming, our_group))

      _ ->
        %AdminActionResponse{status: :CALL_BAD_REQUEST}
    end
  end

  defp manage_sso_map_op(actor, %{op: :SSO_MAP_DELETE} = req) do
    case {nz(req.provider), nz(req.incoming_group)} do
      {provider, incoming} when is_binary(provider) and is_binary(incoming) ->
        action_response(Admin.delete_sso_map(actor, provider, incoming))

      _ ->
        %AdminActionResponse{status: :CALL_BAD_REQUEST}
    end
  end

  defp manage_sso_map_op(_actor, _req), do: %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}

  @spec manage_user(Swarm.Core.V1.ManageUserRequest.t(), GRPC.Server.Stream.t()) ::
          AdminActionResponse.t()
  def manage_user(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      actor = actor_ref(a)

      case req.op do
        :INVITE ->
          do_invite(actor, req)

        :DEACTIVATE ->
          action_response(guarded_target(req.target_user_id, &Admin.deactivate_user(actor, &1)))

        :DELETE ->
          action_response(guarded_target(req.target_user_id, &Admin.delete_user(actor, &1)))

        _ ->
          %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  @spec do_invite(Swarm.Identity.actor_ref(), Swarm.Core.V1.ManageUserRequest.t()) ::
          AdminActionResponse.t()
  defp do_invite(actor, req) do
    # Validate login at the boundary (else the app_user unique/NOT-NULL constraints
    # would 500): non-empty, and not already taken. The pre-check leaves a tiny TOCTOU
    # race that the unique index backstops (admin ops are low-concurrency). Council.
    cond do
      nz(req.login) == nil -> %AdminActionResponse{status: :CALL_BAD_REQUEST}
      Swarm.Identity.by_login(req.login) != nil -> %AdminActionResponse{status: :CALL_BAD_REQUEST}
      true -> do_invite_ok(actor, req)
    end
  end

  @spec do_invite_ok(Swarm.Identity.actor_ref(), Swarm.Core.V1.ManageUserRequest.t()) ::
          AdminActionResponse.t()
  defp do_invite_ok(actor, req) do
    case Admin.invite_user(actor, %{
           login: req.login,
           first_name: nz(req.first_name),
           last_name: nz(req.last_name),
           nickname: nz(req.nickname),
           external: req.external
         }) do
      {:ok, u} -> %AdminActionResponse{status: :CALL_OK, user_id: u.id}
      :not_authorized -> %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}
    end
  end

  # --- Projects (ADR-20) ------------------------------------------------------

  @spec list_projects(ListProjectsRequest.t(), GRPC.Server.Stream.t()) :: ListProjectsResponse.t()
  def list_projects(req, _stream) do
    with_actor(req.assertion, %ListProjectsResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      %ListProjectsResponse{
        status: :CALL_OK,
        projects:
          actor_ref(a)
          |> Admin.list_projects(mine_only: req.mine_only)
          |> Enum.map(&to_project_view/1)
      }
    end)
  end

  @spec get_project(GetProjectRequest.t(), GRPC.Server.Stream.t()) :: GetProjectResponse.t()
  def get_project(req, _stream) do
    with_actor(req.assertion, %GetProjectResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Admin.get_project(actor_ref(a), req.project_id) do
        {:ok, %{project: p, sources: sources, members: members}} ->
          %GetProjectResponse{
            status: :CALL_OK,
            project: to_project_view(p, sources, members),
            sources: Enum.map(sources, &to_source_view/1),
            members: Enum.map(members, &to_member_view/1)
          }

        :not_found ->
          %GetProjectResponse{status: :CALL_NOT_FOUND}
      end
    end)
  end

  @spec manage_project(ManageProjectRequest.t(), GRPC.Server.Stream.t()) ::
          AdminActionResponse.t()
  def manage_project(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      manage_project_op(actor_ref(a), req)
    end)
  end

  @spec manage_project_op(Swarm.Identity.actor_ref(), ManageProjectRequest.t()) ::
          AdminActionResponse.t()
  defp manage_project_op(actor, %{op: :PROJECT_CREATE} = req) do
    attrs = %{name: req.name, description: nz(req.description)}
    attrs = if nz(req.visibility), do: Map.put(attrs, :visibility, req.visibility), else: attrs

    case Admin.create_project(actor, attrs) do
      {:ok, p} -> %AdminActionResponse{status: :CALL_OK, project_id: p.id}
      other -> action_response(other)
    end
  end

  defp manage_project_op(actor, %{op: :PROJECT_RENAME} = req),
    do: action_response(guarded_uuid(req.project_id, &Admin.rename_project(actor, &1, req.name)))

  defp manage_project_op(actor, %{op: :PROJECT_DESCRIBE} = req),
    do:
      action_response(
        guarded_uuid(req.project_id, &Admin.describe_project(actor, &1, nz(req.description)))
      )

  defp manage_project_op(actor, %{op: :PROJECT_SET_VISIBILITY} = req),
    do:
      action_response(
        guarded_uuid(req.project_id, &Admin.set_project_visibility(actor, &1, req.visibility))
      )

  defp manage_project_op(actor, %{op: :PROJECT_DELETE} = req),
    do:
      action_response(guarded_uuid(req.project_id, &Admin.delete_project(actor, &1, req.confirm)))

  defp manage_project_op(actor, %{op: :PROJECT_ADD_SOURCE} = req) do
    guarded_uuid(req.project_id, fn pid ->
      Admin.add_source(actor, pid, %{kind: req.source_kind, label: nz(req.source_label)})
    end)
    |> case do
      {:ok, s} -> %AdminActionResponse{status: :CALL_OK, source_id: s.id, scope: s.scope}
      other -> action_response(other)
    end
  end

  defp manage_project_op(actor, %{op: :PROJECT_REMOVE_SOURCE} = req),
    do: action_response(guarded_uuid(req.source_id, &Admin.remove_source(actor, &1)))

  defp manage_project_op(actor, %{op: :PROJECT_ADD_MEMBER} = req) do
    with_member(req, fn member, pid ->
      Admin.add_project_member(actor, pid, member, role: member_role(req))
    end)
  end

  defp manage_project_op(actor, %{op: :PROJECT_REMOVE_MEMBER} = req) do
    with_member(req, fn member, pid -> Admin.remove_project_member(actor, pid, member) end)
  end

  defp manage_project_op(_actor, _req), do: %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}

  # A member op needs exactly one well-formed member and a uuid-shaped project id.
  defp with_member(req, fun) do
    case member_of(req) do
      nil -> %AdminActionResponse{status: :CALL_BAD_REQUEST}
      member -> action_response(guarded_uuid(req.project_id, &fun.(member, &1)))
    end
  end

  defp member_role(req), do: if(nz(req.member_role), do: req.member_role, else: "member")

  # Exactly one of user / group; a user id must be uuid-shaped (no cast oracle).
  defp member_of(req) do
    case {nz(req.member_user_id), nz(req.member_group_id)} do
      {uid, nil} when is_binary(uid) ->
        if match?({:ok, _}, Ecto.UUID.cast(uid)), do: %{user_id: uid}, else: nil

      {nil, gid} when is_binary(gid) ->
        %{group_id: gid}

      _ ->
        nil
    end
  end

  @spec to_project_view(Swarm.Projects.project(), [map()] | nil, [map()] | nil) :: ProjectView.t()
  defp to_project_view(p, sources \\ nil, members \\ nil) do
    %ProjectView{
      id: p.id,
      name: p.name,
      description: p.description || "",
      visibility: p.visibility,
      source_count: length(sources || Swarm.Projects.sources(p.id)),
      member_count: length(members || Swarm.Projects.members(p.id)),
      created_at: iso(p.created_at)
    }
  end

  @spec to_source_view(Swarm.Projects.source()) :: SourceView.t()
  defp to_source_view(s) do
    %SourceView{
      id: s.id,
      project_id: s.project_id,
      kind: s.kind,
      label: s.label,
      scope: s.scope,
      origin: s.origin,
      created_at: iso(s.created_at)
    }
  end

  @spec to_member_view(Swarm.Projects.member()) :: ProjectMemberView.t()
  defp to_member_view(m) do
    %ProjectMemberView{
      user_id: m.user_id || "",
      group_id: m.group_id || "",
      login: m.login || "",
      name: m.name || "",
      role: m.role
    }
  end

  # --- Elevation (ADR-20) -----------------------------------------------------

  @spec elevate(ElevateRequest.t(), GRPC.Server.Stream.t()) :: ElevateResponse.t()
  def elevate(req, _stream) do
    with_actor(req.assertion, %ElevateResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      opts = if req.ttl_s > 0, do: [ttl_s: req.ttl_s], else: []

      case Elevation.request(%{uuid: a.uuid, sid: a.sid}, req.reason, req.reauth, opts) do
        {:ok, e} ->
          %ElevateResponse{status: :CALL_OK, elevation_id: e.id, expires_at: iso(e.expires_at)}

        {:error, why} when why in [:not_wheel, :not_local, :inactive, :no_session] ->
          %ElevateResponse{status: :CALL_NOT_AUTHORIZED}

        {:error, _reason_or_proof} ->
          %ElevateResponse{status: :CALL_BAD_REQUEST}
      end
    end)
  end

  @spec end_elevation(EndElevationRequest.t(), GRPC.Server.Stream.t()) :: AdminActionResponse.t()
  def end_elevation(req, _stream) do
    with_actor(req.assertion, %AdminActionResponse{status: :CALL_UNAUTHENTICATED}, fn a ->
      case Elevation.end_elevation(%{uuid: a.uuid, sid: a.sid}, nz(req.elevation_id)) do
        :ok -> %AdminActionResponse{status: :CALL_OK}
        :not_found -> %AdminActionResponse{status: :CALL_NOT_FOUND}
        :not_authorized -> %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}
      end
    end)
  end

  # --- helpers --------------------------------------------------------------

  # Legacy-RPC context: dual-accept (verify a signed viewer, else trust plaintext).
  # `:unauthenticated` (strict mode, no assertion) ⇒ anonymous public — fail closed.
  @spec ctx(String.t(), [String.t()]) :: {String.t(), [String.t()], boolean()}
  defp ctx(viewer, wire_scopes) do
    case Auth.legacy_context(viewer, wire_scopes) do
      {:ok, c} -> {c.viewer, c.scopes, c.verified?}
      {:error, :unauthenticated} -> {"", ["public"], false}
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

  # The session-bound actor ref every admin/privacy call derives its caps from.
  @spec actor_ref(Swarm.Actor.actor()) :: {String.t(), String.t() | nil}
  defp actor_ref(a), do: {a.uuid, a.sid}

  # A client-supplied target uuid is validated before it reaches the store (no
  # cast-error 500). Malformed ⇒ `:not_authorized` (fail closed, no oracle).
  @spec guarded_target(String.t(), (String.t() -> term())) :: term() | :not_authorized
  defp guarded_target(target_id, fun) do
    case Ecto.UUID.cast(target_id) do
      {:ok, _} -> fun.(target_id)
      :error -> :not_authorized
    end
  end

  # A client-supplied project/source id: malformed ⇒ NOT_FOUND (no existence oracle).
  @spec guarded_uuid(String.t(), (String.t() -> term())) :: term() | :not_found
  defp guarded_uuid(id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> fun.(id)
      :error -> :not_found
    end
  end

  @spec guarded_group_id(String.t(), (String.t() -> term())) :: term() | {:error, :bad_group_id}
  defp guarded_group_id(group_id, fun) do
    case nz(group_id) do
      nil -> {:error, :bad_group_id}
      id -> fun.(id)
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

  @spec action_response(term()) :: AdminActionResponse.t()
  defp action_response(:ok), do: %AdminActionResponse{status: :CALL_OK}
  defp action_response(:not_authorized), do: %AdminActionResponse{status: :CALL_NOT_AUTHORIZED}
  defp action_response(:not_found), do: %AdminActionResponse{status: :CALL_NOT_FOUND}
  defp action_response(:not_confirmed), do: %AdminActionResponse{status: :CALL_BAD_REQUEST}
  defp action_response({:ok, _}), do: %AdminActionResponse{status: :CALL_OK}

  # `:not_found` from the store (unknown project/source/member) is a 404, not an oracle.
  defp action_response({:error, :not_found}), do: %AdminActionResponse{status: :CALL_NOT_FOUND}

  # Every other rejection is a CALLER error: an ungrantable/unknown value, a forbidden
  # per-user role or group scope grant, a fixed-group lifecycle op, a Wheel policy refusal
  # (local-only / last member / SSO→wheel), a self-grant, an invalid role/kind/visibility.
  defp action_response({:error, _reason}), do: %AdminActionResponse{status: :CALL_BAD_REQUEST}

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

  @spec iso_or_empty(term()) :: String.t()
  defp iso_or_empty(nil), do: ""
  defp iso_or_empty(dt), do: iso(dt)
end
