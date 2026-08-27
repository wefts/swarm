defmodule Swarm.CoreIdentityRpcTest do
  @moduledoc """
  Workspace ADR-16 step 6a + ADR-20 — the Core gRPC surface for identity/privacy/projects/
  elevation. The identity RPCs are ALWAYS strict: they carry a signed actor assertion, verify
  it, and derive the subject — a plaintext or forged assertion is UNAUTHENTICATED. Caps are
  derived for the assertion's SESSION (an elevation is session-bound). Handlers are called
  directly (they ignore the stream).
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Elevation, Identity, Projects}
  alias Swarm.Core.{Auth, Server}

  alias Swarm.Core.V1.{
    AdminReadConversationRequest,
    AskRequest,
    ElevateRequest,
    EndElevationRequest,
    GetConversationRequest,
    GetProjectRequest,
    GetUserRequest,
    ListConversationsRequest,
    ListProjectsRequest,
    LogConversationRequest,
    ManageAccessRequest,
    ManageProjectRequest,
    ManageUserRequest,
    ProvisionActorRequest,
    ResolveActorRequest
  }

  @sid "rpc-sess"

  defp provision(login, subject, groups \\ []) do
    {:ok, u} =
      Identity.upsert_from_claims(%{
        provider: "keycloak",
        subject: subject,
        login: login,
        groups: groups
      })

    u
  end

  # A signed assertion for a (provisioned) subject, using the config test secret.
  defp assertion(subject, sid \\ @sid),
    do: Actor.sign(%{"sub" => subject, "provider" => "keycloak", "sid" => sid})

  defp local_assertion(login, sid \\ @sid),
    do: Actor.sign(%{"sub" => login, "provider" => "local", "sid" => sid})

  defp reauth(login, sid \\ @sid) do
    Actor.sign(
      %{
        "aud" => Actor.reauth_audience(),
        "sub" => login,
        "provider" => "local",
        "sid" => sid,
        "jti" => "jti-#{System.unique_integer([:positive])}",
        "auth_time" => System.system_time(:second)
      },
      exp_in: 60
    )
  end

  # A Wheel member + an ELEVATED assertion for session @sid.
  defp elevated_wheel(login \\ "root#{System.unique_integer([:positive])}") do
    {:ok, u} = Identity.seed_wheel(%{id: Identity.uuid7(), login: login})
    {:ok, _} = Elevation.request(%{uuid: u.id, sid: @sid}, "test", reauth(login))
    {u, local_assertion(login)}
  end

  defp make_admin(user_id), do: :ok = Identity.add_to_group(user_id, "admins")

  describe "ResolveActor" do
    test "a valid assertion returns the derived uuid/scopes/caps and the (absent) elevation" do
      internal = register_source!(name: "Internal", members: [%{group_id: "staff"}])
      u = provision("penta", "sub-penta")

      resp = Server.resolve_actor(%ResolveActorRequest{assertion: assertion("sub-penta")}, nil)
      assert resp.status == :CALL_OK
      assert resp.uuid == u.id
      assert resp.login == "penta"
      assert Enum.sort(resp.scopes) == Enum.sort(["public", internal])
      assert resp.caps == []
      assert resp.elevation_expires_at == ""
      assert resp.external == false
    end

    test "a garbage assertion ⇒ UNAUTHENTICATED" do
      resp = Server.resolve_actor(%ResolveActorRequest{assertion: "not.a.token"}, nil)
      assert resp.status == :CALL_UNAUTHENTICATED
    end
  end

  describe "ProvisionActor (ADR-16 D3 — JIT over the wire)" do
    defp provision_token(claims), do: Actor.sign(Map.put_new(claims, "aud", "swarm.provision.v1"))

    test "a NEW SSO subject is JIT-provisioned into the default cohort; scopes derive from Projects" do
      internal = register_source!(name: "Internal", members: [%{group_id: "staff"}])

      t =
        provision_token(%{
          "sub" => "sub-fresh",
          "provider" => "keycloak",
          "login" => "fresh",
          "first_name" => "Fresh",
          "email" => "fresh@example.test",
          "groups" => ["whatever"]
        })

      resp = Server.provision_actor(%ProvisionActorRequest{provision: t}, nil)
      assert resp.status == :CALL_OK
      assert resp.login == "fresh"
      assert Enum.sort(resp.scopes) == Enum.sort(["public", internal])

      resolved =
        Server.resolve_actor(%ResolveActorRequest{assertion: assertion("sub-fresh")}, nil)

      assert resolved.status == :CALL_OK
      assert resolved.uuid == resp.uuid
    end

    test "re-provision on every login re-syncs mapped groups (privilege retention closed)" do
      :ok = Identity.put_sso_group_map("keycloak", "DSI", "admins")

      t1 =
        provision_token(%{
          "sub" => "sub-syncer",
          "provider" => "keycloak",
          "login" => "syncer",
          "groups" => ["DSI"]
        })

      first = Server.provision_actor(%ProvisionActorRequest{provision: t1}, nil)
      assert "manage_access" in first.caps

      # the IdP drops the group — the next login must NOT retain the role
      t2 =
        provision_token(%{
          "sub" => "sub-syncer",
          "provider" => "keycloak",
          "login" => "syncer",
          "groups" => []
        })

      second = Server.provision_actor(%ProvisionActorRequest{provision: t2}, nil)
      assert second.status == :CALL_OK and second.uuid == first.uuid
      assert second.caps == []
      assert Identity.groups_for(first.uuid) == ["staff"]
    end

    test "an ACTOR assertion cannot provision (audience binding, cross-use closed)" do
      provision("penta", "sub-penta")

      resp =
        Server.provision_actor(%ProvisionActorRequest{provision: assertion("sub-penta")}, nil)

      assert resp.status == :CALL_UNAUTHENTICATED
    end

    test "a deactivated account does NOT resurrect via provisioning" do
      {_root, root_t} = elevated_wheel()
      u = provision("victim", "sub-victim")

      assert Server.manage_user(
               %ManageUserRequest{assertion: root_t, op: :DEACTIVATE, target_user_id: u.id},
               nil
             ).status == :CALL_OK

      t =
        provision_token(%{
          "sub" => "sub-victim",
          "provider" => "keycloak",
          "login" => "victim-renamed",
          "groups" => []
        })

      resp = Server.provision_actor(%ProvisionActorRequest{provision: t}, nil)
      # indistinguishable from unknown/garbage — no disabled-account oracle
      assert resp.status == :CALL_UNAUTHENTICATED
      after_u = Identity.get_user(u.id)
      assert after_u.status == "disabled" and after_u.login == "victim"
      assert Identity.groups_for(u.id) == []
    end

    test "a login collision with an existing identity is refused loud, never auto-linked" do
      provision("penta", "sub-penta")

      t =
        provision_token(%{
          "sub" => "sub-imposter",
          "provider" => "keycloak",
          "login" => "penta",
          "groups" => []
        })

      resp = Server.provision_actor(%ProvisionActorRequest{provision: t}, nil)
      assert resp.status == :CALL_BAD_REQUEST
      assert Identity.user_by_link("keycloak", "sub-imposter") == nil
    end

    test "an INVITED account's login cannot be hijacked by a new SSO subject" do
      {_root, root_t} = elevated_wheel()

      inv =
        Server.manage_user(
          %ManageUserRequest{assertion: root_t, op: :INVITE, login: "newby"},
          nil
        )

      assert inv.status == :CALL_OK

      t =
        provision_token(%{
          "sub" => "sub-newby-sso",
          "provider" => "keycloak",
          "login" => "newby",
          "groups" => []
        })

      assert Server.provision_actor(%ProvisionActorRequest{provision: t}, nil).status ==
               :CALL_BAD_REQUEST
    end
  end

  describe "conversation RPCs (owner-private, strict)" do
    test "log then get round-trips for the owner" do
      provision("penta", "sub-penta")
      t = assertion("sub-penta")

      log =
        Server.log_conversation(
          %LogConversationRequest{assertion: t, title: "plan", role: "user", body: "hello"},
          nil
        )

      assert log.status == :CALL_OK
      assert log.conversation_id != "" and log.message_id != ""

      log2 =
        Server.log_conversation(
          %LogConversationRequest{
            assertion: t,
            conversation_id: log.conversation_id,
            role: "assistant",
            body: "hi",
            ask_ref: "r1"
          },
          nil
        )

      assert log2.status == :CALL_OK

      get =
        Server.get_conversation(
          %GetConversationRequest{assertion: t, conversation_id: log.conversation_id},
          nil
        )

      assert get.status == :CALL_OK
      assert get.conversation.title == "plan"
      assert Enum.map(get.messages, & &1.body) == ["hello", "hi"]
    end

    test "no-leak THROUGH THE RPC: another actor gets NOT_FOUND for someone else's conversation" do
      provision("alice", "sub-alice")
      provision("bob", "sub-bob")

      log =
        Server.log_conversation(
          %LogConversationRequest{
            assertion: assertion("sub-alice"),
            title: "secret",
            role: "user",
            body: "x"
          },
          nil
        )

      resp =
        Server.get_conversation(
          %GetConversationRequest{
            assertion: assertion("sub-bob"),
            conversation_id: log.conversation_id
          },
          nil
        )

      assert resp.status == :CALL_NOT_FOUND
    end

    test "list returns only the actor's own conversations; unauthenticated cannot log or list" do
      provision("alice", "sub-alice")
      provision("bob", "sub-bob")

      Server.log_conversation(
        %LogConversationRequest{
          assertion: assertion("sub-alice"),
          title: "a",
          role: "user",
          body: "x"
        },
        nil
      )

      Server.log_conversation(
        %LogConversationRequest{
          assertion: assertion("sub-bob"),
          title: "b",
          role: "user",
          body: "y"
        },
        nil
      )

      resp =
        Server.list_conversations(
          %ListConversationsRequest{assertion: assertion("sub-alice")},
          nil
        )

      assert resp.status == :CALL_OK
      assert Enum.map(resp.conversations, & &1.title) == ["a"]

      assert Server.log_conversation(
               %LogConversationRequest{assertion: "x", role: "user", body: "z"},
               nil
             ).status == :CALL_UNAUTHENTICATED

      assert Server.list_conversations(%ListConversationsRequest{assertion: "x"}, nil).status ==
               :CALL_UNAUTHENTICATED
    end
  end

  describe "AdminReadConversation (break-glass — elevated session only)" do
    test "an ELEVATED Wheel member reads another user's conversation; the same user's cold session and a plain user cannot" do
      bob = provision("bob", "sub-bob")
      {root, root_t} = elevated_wheel("rootbg")

      log =
        Server.log_conversation(
          %LogConversationRequest{
            assertion: assertion("sub-bob"),
            title: "bobs",
            role: "user",
            body: "hush"
          },
          nil
        )

      ok =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: root_t,
            conversation_id: log.conversation_id,
            reason: "ticket"
          },
          nil
        )

      assert ok.status == :CALL_OK
      assert ok.conversation.owner_id == bob.id
      assert Enum.map(ok.messages, & &1.body) == ["hush"]

      cold =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: local_assertion(root.login, "cold"),
            conversation_id: log.conversation_id,
            reason: "ticket"
          },
          nil
        )

      assert cold.status == :CALL_NOT_AUTHORIZED

      provision("mallory", "sub-mallory")

      denied =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: assertion("sub-mallory"),
            conversation_id: log.conversation_id,
            reason: "peek"
          },
          nil
        )

      assert denied.status == :CALL_NOT_AUTHORIZED
    end

    test "requires a non-empty reason (break-glass accountability)" do
      {_root, root_t} = elevated_wheel()
      provision("bob", "sub-bob")

      log =
        Server.log_conversation(
          %LogConversationRequest{
            assertion: assertion("sub-bob"),
            title: "b",
            role: "user",
            body: "x"
          },
          nil
        )

      resp =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: root_t,
            conversation_id: log.conversation_id,
            reason: ""
          },
          nil
        )

      assert resp.status == :CALL_BAD_REQUEST
    end
  end

  describe "admin RPCs (ManageAccess / ManageUser)" do
    test "GRANT_ROLE / SET_GROUP_SCOPES are BAD_REQUEST; admin comes from the admins group; plain users are NOT_AUTHORIZED" do
      {_root, root_t} = elevated_wheel()
      u = provision("penta", "sub-penta")

      forbidden =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: root_t,
            op: :GRANT_ROLE,
            target_user_id: u.id,
            role: "admin"
          },
          nil
        )

      assert forbidden.status == :CALL_BAD_REQUEST
      refute "admin" in Identity.roles_for(u.id)

      rejected =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: root_t,
            op: :SET_GROUP_SCOPES,
            group_id: "staff",
            scopes: ["public"]
          },
          nil
        )

      assert rejected.status == :CALL_BAD_REQUEST

      granted =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: root_t,
            op: :GRANT_GROUP,
            target_user_id: u.id,
            group_id: "admins"
          },
          nil
        )

      assert granted.status == :CALL_OK
      assert "admin" in Identity.roles_for(u.id)

      provision("mallory", "sub-mallory")

      denied =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: assertion("sub-mallory"),
            op: :GRANT_GROUP,
            target_user_id: u.id,
            group_id: "admins"
          },
          nil
        )

      assert denied.status == :CALL_NOT_AUTHORIZED
    end

    test "GRANT_GROUP wheel: an admin is NOT_AUTHORIZED, an SSO user is BAD_REQUEST (local-only), a local user works when elevated" do
      {_root, root_t} = elevated_wheel()
      admin = provision("adm", "sub-adm")
      make_admin(admin.id)
      kc = provision("kc", "sub-kc")
      {:ok, loc} = Identity.invite_user(%{login: "loc"})

      assert Server.manage_access(
               %ManageAccessRequest{
                 assertion: assertion("sub-adm"),
                 op: :GRANT_GROUP,
                 target_user_id: loc.id,
                 group_id: "wheel"
               },
               nil
             ).status ==
               :CALL_NOT_AUTHORIZED

      assert Server.manage_access(
               %ManageAccessRequest{
                 assertion: root_t,
                 op: :GRANT_GROUP,
                 target_user_id: kc.id,
                 group_id: "wheel"
               },
               nil
             ).status ==
               :CALL_BAD_REQUEST

      assert Server.manage_access(
               %ManageAccessRequest{
                 assertion: root_t,
                 op: :GRANT_GROUP,
                 target_user_id: loc.id,
                 group_id: "wheel"
               },
               nil
             ).status ==
               :CALL_OK

      assert "wheel" in Identity.groups_for(loc.id)
    end

    test "an admin invites a user or a GUEST via ManageUser; malformed/duplicate input is fail-closed" do
      penta = provision("penta", "sub-penta")
      make_admin(penta.id)
      t = assertion("sub-penta")

      inv =
        Server.manage_user(%ManageUserRequest{assertion: t, op: :INVITE, login: "newbie"}, nil)

      assert inv.status == :CALL_OK
      assert Identity.by_login("newbie").id == inv.user_id

      guest =
        Server.manage_user(
          %ManageUserRequest{assertion: t, op: :INVITE, login: "visitor", external: true},
          nil
        )

      assert guest.status == :CALL_OK
      assert Identity.get_user(guest.user_id).external
      assert Identity.groups_for(guest.user_id) == []

      detail = Server.get_user(%GetUserRequest{assertion: t, user_id: guest.user_id}, nil)
      assert detail.status == :CALL_OK and detail.user.external

      assert Server.manage_user(
               %ManageUserRequest{assertion: t, op: :DEACTIVATE, target_user_id: "not-a-uuid"},
               nil
             ).status == :CALL_NOT_AUTHORIZED

      assert Server.manage_user(%ManageUserRequest{assertion: t, op: :INVITE, login: ""}, nil).status ==
               :CALL_BAD_REQUEST

      assert Server.manage_user(
               %ManageUserRequest{assertion: t, op: :INVITE, login: "penta"},
               nil
             ).status == :CALL_BAD_REQUEST
    end

    test "LogConversation rejects an invalid message role and creates nothing" do
      provision("penta", "sub-penta")

      resp =
        Server.log_conversation(
          %LogConversationRequest{
            assertion: assertion("sub-penta"),
            title: "x",
            role: "system",
            body: "hi"
          },
          nil
        )

      assert resp.status == :CALL_BAD_REQUEST

      assert Server.list_conversations(
               %ListConversationsRequest{assertion: assertion("sub-penta")},
               nil
             ).conversations == []
    end
  end

  describe "Project RPCs (ADR-20)" do
    test "an admin creates a Project, adds a Source (minting its scope) and a member; the member sees it, a stranger gets NOT_FOUND" do
      adm = provision("adm", "sub-adm")
      make_admin(adm.id)
      t = assertion("sub-adm")
      member = provision("member", "sub-member")
      provision("stranger", "sub-stranger")

      created =
        Server.manage_project(
          %ManageProjectRequest{
            assertion: t,
            op: :PROJECT_CREATE,
            name: "Team wiki",
            description: "pages"
          },
          nil
        )

      assert created.status == :CALL_OK and created.project_id != ""

      added =
        Server.manage_project(
          %ManageProjectRequest{
            assertion: t,
            op: :PROJECT_ADD_SOURCE,
            project_id: created.project_id,
            source_kind: "wiki",
            source_label: "Team wiki"
          },
          nil
        )

      assert added.status == :CALL_OK
      assert added.scope == "src:" <> added.source_id
      assert Projects.registered_scope?(added.scope)

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: t,
                 op: :PROJECT_ADD_MEMBER,
                 project_id: created.project_id,
                 member_user_id: member.id
               },
               nil
             ).status == :CALL_OK

      resolved =
        Server.resolve_actor(%ResolveActorRequest{assertion: assertion("sub-member")}, nil)

      assert added.scope in resolved.scopes

      got =
        Server.get_project(
          %GetProjectRequest{assertion: assertion("sub-member"), project_id: created.project_id},
          nil
        )

      assert got.status == :CALL_OK

      assert got.project.name == "Team wiki" and got.project.source_count == 1 and
               got.project.member_count == 2

      assert Enum.map(got.sources, & &1.scope) == [added.scope]
      assert Enum.sort(Enum.map(got.members, & &1.login)) == ["adm", "member"]

      assert Server.get_project(
               %GetProjectRequest{
                 assertion: assertion("sub-stranger"),
                 project_id: created.project_id
               },
               nil
             ).status == :CALL_NOT_FOUND

      assert Server.get_project(%GetProjectRequest{assertion: t, project_id: "garbage"}, nil).status ==
               :CALL_NOT_FOUND

      mine = Server.list_projects(%ListProjectsRequest{assertion: assertion("sub-member")}, nil)
      assert Enum.map(mine.projects, & &1.id) == [created.project_id]

      assert Server.list_projects(%ListProjectsRequest{assertion: assertion("sub-stranger")}, nil).projects ==
               []

      assert length(Server.list_projects(%ListProjectsRequest{assertion: t}, nil).projects) == 1

      # a member is not a manager
      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: assertion("sub-member"),
                 op: :PROJECT_RENAME,
                 project_id: created.project_id,
                 name: "x"
               },
               nil
             ).status == :CALL_NOT_AUTHORIZED
    end

    test "publicness over the wire needs an elevation; a self-grant is BAD_REQUEST" do
      adm = provision("adm", "sub-adm")
      make_admin(adm.id)
      other = provision("other", "sub-other")
      make_admin(other.id)
      t = assertion("sub-adm")

      created =
        Server.manage_project(
          %ManageProjectRequest{
            assertion: assertion("sub-other"),
            op: :PROJECT_CREATE,
            name: "Other's"
          },
          nil
        )

      pid = created.project_id

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: t,
                 op: :PROJECT_SET_VISIBILITY,
                 project_id: pid,
                 visibility: "public"
               },
               nil
             ).status == :CALL_NOT_AUTHORIZED

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: t,
                 op: :PROJECT_CREATE,
                 name: "Pub",
                 visibility: "public"
               },
               nil
             ).status == :CALL_NOT_AUTHORIZED

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: t,
                 op: :PROJECT_ADD_MEMBER,
                 project_id: pid,
                 member_user_id: adm.id
               },
               nil
             ).status == :CALL_BAD_REQUEST

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: t,
                 op: :PROJECT_ADD_MEMBER,
                 project_id: pid,
                 member_user_id: adm.id,
                 member_group_id: "staff"
               },
               nil
             ).status == :CALL_BAD_REQUEST

      {_root, root_t} = elevated_wheel()

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: root_t,
                 op: :PROJECT_SET_VISIBILITY,
                 project_id: pid,
                 visibility: "public"
               },
               nil
             ).status == :CALL_OK

      assert Projects.get_project(pid).visibility == "public"

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: t,
                 op: :PROJECT_ADD_SOURCE,
                 project_id: pid,
                 source_kind: "wiki"
               },
               nil
             ).status == :CALL_NOT_AUTHORIZED

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: root_t,
                 op: :PROJECT_DELETE,
                 project_id: pid,
                 confirm: true
               },
               nil
             ).status == :CALL_OK

      assert Server.manage_project(
               %ManageProjectRequest{
                 assertion: root_t,
                 op: :PROJECT_DELETE,
                 project_id: pid,
                 confirm: true
               },
               nil
             ).status == :CALL_NOT_FOUND
    end
  end

  describe "Elevate / EndElevation RPCs" do
    test "a local Wheel member elevates with a fresh proof; caps flip for that session; ending it flips them back" do
      {:ok, u} = Identity.seed_wheel(%{id: Identity.uuid7(), login: "rootrpc"})
      t = local_assertion("rootrpc")

      before = Server.resolve_actor(%ResolveActorRequest{assertion: t}, nil)
      refute "read_any_conversation" in before.caps

      resp =
        Server.elevate(
          %ElevateRequest{assertion: t, reason: "incident", reauth: reauth("rootrpc")},
          nil
        )

      assert resp.status == :CALL_OK and resp.elevation_id != "" and resp.expires_at != ""

      after_ = Server.resolve_actor(%ResolveActorRequest{assertion: t}, nil)
      assert "read_any_conversation" in after_.caps
      assert after_.elevation_expires_at == resp.expires_at

      cold =
        Server.resolve_actor(
          %ResolveActorRequest{assertion: local_assertion("rootrpc", "cold")},
          nil
        )

      refute "read_any_conversation" in cold.caps

      assert Server.end_elevation(%EndElevationRequest{assertion: t}, nil).status == :CALL_OK

      refute "read_any_conversation" in Server.resolve_actor(
               %ResolveActorRequest{assertion: t},
               nil
             ).caps

      assert Server.end_elevation(%EndElevationRequest{assertion: t}, nil).status ==
               :CALL_NOT_FOUND

      assert Elevation.active_holder_count() == 0
      _ = u
    end

    test "refusals map honestly: not Wheel ⇒ NOT_AUTHORIZED; bad proof / blank reason ⇒ BAD_REQUEST; garbage ⇒ UNAUTHENTICATED" do
      provision("penta", "sub-penta")

      assert Server.elevate(
               %ElevateRequest{assertion: assertion("sub-penta"), reason: "r", reauth: "x"},
               nil
             ).status == :CALL_NOT_AUTHORIZED

      {:ok, _} = Identity.seed_wheel(%{id: Identity.uuid7(), login: "rootrpc2"})
      t = local_assertion("rootrpc2")

      assert Server.elevate(
               %ElevateRequest{assertion: t, reason: "", reauth: reauth("rootrpc2")},
               nil
             ).status == :CALL_BAD_REQUEST

      assert Server.elevate(%ElevateRequest{assertion: t, reason: "r", reauth: "garbage"}, nil).status ==
               :CALL_BAD_REQUEST

      assert Server.elevate(
               %ElevateRequest{
                 assertion: t,
                 reason: "r",
                 reauth: reauth("rootrpc2", "other-sid")
               },
               nil
             ).status == :CALL_BAD_REQUEST

      assert Server.elevate(%ElevateRequest{assertion: "nope", reason: "r", reauth: "x"}, nil).status ==
               :CALL_UNAUTHENTICATED

      assert Server.end_elevation(%EndElevationRequest{assertion: "nope"}, nil).status ==
               :CALL_UNAUTHENTICATED
    end
  end

  describe "dual-accept auth seam (legacy RPCs keep working)" do
    setup do
      prev = Application.get_env(:swarm, :core_api)
      Application.put_env(:swarm, :core_api, Keyword.put(prev, :auth_mode, :dual))
      on_exit(fn -> Application.put_env(:swarm, :core_api, prev) end)
      :ok
    end

    test "legacy_context in :dual passes a plaintext viewer through unchanged" do
      src = Swarm.GraphCase.test_src()
      assert {:ok, %{viewer: "alice", scopes: [^src]}} = Auth.legacy_context("alice", [src])
    end

    test "legacy_context in :dual verifies + derives a signed viewer (ignoring wire scopes)" do
      u = provision("penta", "sub-penta")
      t = assertion("sub-penta")
      # wire scopes claim [src,private] but the DERIVED scopes win
      assert {:ok, %{viewer: v, scopes: ["public"]}} =
               Auth.legacy_context(t, [Swarm.GraphCase.test_src(), "private"])

      assert v == u.id
    end

    test "Ask still answers with a plaintext viewer (live channel unbroken)" do
      resp = Server.ask(%AskRequest{query: "anything", scopes: ["public"], viewer: "alice"}, nil)
      assert resp.status in [:FOUND, :NOT_FOUND, :PARTIAL, :ERROR]
    end

    test "an assertion-shaped viewer that fails verification is NOT trusted as a plaintext id" do
      forged = "aaa.bbb.ccc"

      assert {:ok, %{viewer: "", scopes: ["public"]}} =
               Auth.legacy_context(forged, [Swarm.GraphCase.test_src()])
    end

    test ":strict rejects a plaintext viewer (the post-6b cutover posture)" do
      prev = Application.get_env(:swarm, :core_api)
      Application.put_env(:swarm, :core_api, Keyword.put(prev, :auth_mode, :strict))
      on_exit(fn -> Application.put_env(:swarm, :core_api, prev) end)

      assert Auth.legacy_context("alice", [Swarm.GraphCase.test_src()]) ==
               {:error, :unauthenticated}

      provision("penta", "sub-penta")
      assert {:ok, %{}} = Auth.legacy_context(assertion("sub-penta"), [])
    end
  end
end
