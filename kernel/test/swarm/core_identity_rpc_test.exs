defmodule Swarm.CoreIdentityRpcTest do
  @moduledoc """
  Workspace ADR-16 step 6a — the Core gRPC surface for identity/privacy. The new
  RPCs (ResolveActor / conversation Log/List/Get / admin) are ALWAYS strict: they
  carry a signed actor assertion, verify it, and derive the subject — a plaintext or
  forged assertion is UNAUTHENTICATED. The older RPCs dual-accept (verify a signed
  `viewer`, else trust plaintext) so the live channel keeps working (6b flips strict).
  Handlers are called directly (they ignore the stream).
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Identity}
  alias Swarm.Core.{Auth, Server}

  alias Swarm.Core.V1.{
    AdminReadConversationRequest,
    AskRequest,
    GetConversationRequest,
    ListConversationsRequest,
    LogConversationRequest,
    ManageAccessRequest,
    ManageUserRequest,
    ProvisionActorRequest,
    ResolveActorRequest
  }

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
  defp assertion(subject), do: Actor.sign(%{"sub" => subject, "provider" => "keycloak"})

  defp superadmin_assertion do
    {:ok, u} =
      Identity.seed_superadmin(%{
        id: Identity.uuid7(),
        login: "root#{System.unique_integer([:positive])}"
      })

    {u, Actor.sign(%{"sub" => u.login, "provider" => "local"})}
  end

  describe "ResolveActor" do
    test "a valid assertion returns the derived uuid/scopes/caps" do
      Identity.put_group_scopes("staff", ["public", "group"])
      u = provision("penta", "sub-penta", ["staff"])

      resp = Server.resolve_actor(%ResolveActorRequest{assertion: assertion("sub-penta")}, nil)
      assert resp.status == :CALL_OK
      assert resp.uuid == u.id
      assert resp.login == "penta"
      assert Enum.sort(resp.scopes) == ["group", "public"]
      assert resp.caps == []
    end

    test "a garbage assertion ⇒ UNAUTHENTICATED" do
      resp = Server.resolve_actor(%ResolveActorRequest{assertion: "not.a.token"}, nil)
      assert resp.status == :CALL_UNAUTHENTICATED
    end
  end

  describe "ProvisionActor (ADR-16 D3 — JIT over the wire)" do
    # The ENTIRE claim set rides inside the signed provision token (aud
    # "swarm.provision.v1") — council: unsigned request-field groups would let any
    # assertion holder self-assert scopes.
    defp provision_token(claims) do
      Actor.sign(Map.put_new(claims, "aud", "swarm.provision.v1"))
    end

    test "a NEW SSO subject is JIT-provisioned; scopes derive from synced groups" do
      Identity.put_group_scopes("staff", ["public", "group"])

      t =
        provision_token(%{
          "sub" => "sub-fresh",
          "provider" => "keycloak",
          "login" => "fresh",
          "first_name" => "Fresh",
          "email" => "fresh@example.test",
          "groups" => ["staff"]
        })

      resp = Server.provision_actor(%ProvisionActorRequest{provision: t}, nil)
      assert resp.status == :CALL_OK
      assert resp.login == "fresh"
      assert Enum.sort(resp.scopes) == ["group", "public"]

      # and the subject now RESOLVES like any migrated account
      resolved =
        Server.resolve_actor(%ResolveActorRequest{assertion: assertion("sub-fresh")}, nil)

      assert resolved.status == :CALL_OK
      assert resolved.uuid == resp.uuid
    end

    test "re-provision on every login re-syncs groups (privilege retention closed)" do
      Identity.put_group_scopes("staff", ["group"])

      t1 =
        provision_token(%{
          "sub" => "sub-syncer",
          "provider" => "keycloak",
          "login" => "syncer",
          "groups" => ["staff"]
        })

      first = Server.provision_actor(%ProvisionActorRequest{provision: t1}, nil)
      assert Enum.sort(first.scopes) == ["group", "public"]

      # the IdP drops the group — the next login must NOT retain the scope
      t2 =
        provision_token(%{
          "sub" => "sub-syncer",
          "provider" => "keycloak",
          "login" => "syncer",
          "groups" => []
        })

      second = Server.provision_actor(%ProvisionActorRequest{provision: t2}, nil)
      assert second.status == :CALL_OK
      assert second.uuid == first.uuid
      # the group scope is gone; the authenticated public baseline remains
      assert second.scopes == ["public"]
    end

    test "an ACTOR assertion cannot provision (audience binding, cross-use closed)" do
      provision("penta", "sub-penta")

      resp =
        Server.provision_actor(%ProvisionActorRequest{provision: assertion("sub-penta")}, nil)

      assert resp.status == :CALL_UNAUTHENTICATED
    end

    test "a deactivated account does NOT resurrect via provisioning" do
      {_root, root_t} = superadmin_assertion()
      u = provision("victim", "sub-victim")

      Server.manage_user(
        %ManageUserRequest{assertion: root_t, op: :DEACTIVATE, target_user_id: u.id},
        nil
      )

      t =
        provision_token(%{
          "sub" => "sub-victim",
          "provider" => "keycloak",
          "login" => "victim-renamed",
          "groups" => ["staff"]
        })

      resp = Server.provision_actor(%ProvisionActorRequest{provision: t}, nil)
      # indistinguishable from unknown/garbage — no disabled-account oracle
      assert resp.status == :CALL_UNAUTHENTICATED
      # nothing was refreshed: status stays disabled, login unchanged, no group sync
      after_u = Identity.get_user(u.id)
      assert after_u.status == "disabled"
      assert after_u.login == "victim"
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
      # no second identity was minted for the taken login
      assert Identity.user_by_link("keycloak", "sub-imposter") == nil
    end

    test "an INVITED account is promoted to active by its first provisioned login" do
      {_root, root_t} = superadmin_assertion()

      inv =
        Server.manage_user(
          %ManageUserRequest{assertion: root_t, op: :INVITE, login: "newby"},
          nil
        )

      assert inv.status == :CALL_OK
      # the invited user's identity_link is local — an SSO provision for a NEW
      # subject with the same login must NOT hijack it (collision path)…
      t =
        provision_token(%{
          "sub" => "sub-newby-sso",
          "provider" => "keycloak",
          "login" => "newby",
          "groups" => []
        })

      resp = Server.provision_actor(%ProvisionActorRequest{provision: t}, nil)
      assert resp.status == :CALL_BAD_REQUEST
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

    test "list returns only the actor's own conversations" do
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
    end

    test "an unauthenticated assertion cannot log or list" do
      assert Server.log_conversation(
               %LogConversationRequest{assertion: "x", role: "user", body: "z"},
               nil
             ).status == :CALL_UNAUTHENTICATED

      assert Server.list_conversations(%ListConversationsRequest{assertion: "x"}, nil).status ==
               :CALL_UNAUTHENTICATED
    end
  end

  describe "AdminReadConversation (break-glass)" do
    test "a superadmin reads another user's conversation; a plain user cannot" do
      bob = provision("bob", "sub-bob")
      {_root, root_t} = superadmin_assertion()

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
  end

  describe "admin RPCs (ManageAccess / ManageUser)" do
    test "superadmin grants a role via ManageAccess; a plain user is NOT_AUTHORIZED" do
      {_root, root_t} = superadmin_assertion()
      u = provision("penta", "sub-penta")

      ok =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: root_t,
            op: :GRANT_ROLE,
            target_user_id: u.id,
            role: "admin"
          },
          nil
        )

      assert ok.status == :CALL_OK
      assert "admin" in Identity.roles_for(u.id)

      provision("mallory", "sub-mallory")

      denied =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: assertion("sub-mallory"),
            op: :GRANT_ROLE,
            target_user_id: u.id,
            role: "superadmin"
          },
          nil
        )

      assert denied.status == :CALL_NOT_AUTHORIZED
    end

    test "SET_GROUP_SCOPES with private is BAD_REQUEST — the leak-guard at the wire" do
      {_root, root_t} = superadmin_assertion()

      rejected =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: root_t,
            op: :SET_GROUP_SCOPES,
            group_id: "nebula",
            scopes: ["group", "private"]
          },
          nil
        )

      assert rejected.status == :CALL_BAD_REQUEST

      # the vocabulary check rides the same boundary
      unknown =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: root_t,
            op: :SET_GROUP_SCOPES,
            group_id: "nebula",
            scopes: ["secret"]
          },
          nil
        )

      assert unknown.status == :CALL_BAD_REQUEST
    end

    test "an admin invites a user via ManageUser; a malformed target is fail-closed" do
      # make penta an admin (via superadmin), then penta invites
      {_root, root_t} = superadmin_assertion()
      penta = provision("penta", "sub-penta")

      Server.manage_access(
        %ManageAccessRequest{
          assertion: root_t,
          op: :GRANT_ROLE,
          target_user_id: penta.id,
          role: "admin"
        },
        nil
      )

      inv =
        Server.manage_user(
          %ManageUserRequest{assertion: assertion("sub-penta"), op: :INVITE, login: "newbie"},
          nil
        )

      assert inv.status == :CALL_OK
      assert Identity.by_login("newbie").id == inv.user_id

      # a malformed target uuid on deactivate ⇒ NOT_AUTHORIZED (no cast-500)
      bad =
        Server.manage_user(
          %ManageUserRequest{
            assertion: assertion("sub-penta"),
            op: :DEACTIVATE,
            target_user_id: "not-a-uuid"
          },
          nil
        )

      assert bad.status == :CALL_NOT_AUTHORIZED
    end
  end

  describe "boundary validation (malformed input ⇒ CALL_BAD_REQUEST, never a 500)" do
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
      # no ghost conversation left behind
      list =
        Server.list_conversations(
          %ListConversationsRequest{assertion: assertion("sub-penta")},
          nil
        )

      assert list.conversations == []
    end

    test "ManageAccess rejects a bogus role before hitting the DB CHECK" do
      {_root, root_t} = superadmin_assertion()
      u = provision("penta", "sub-penta")

      resp =
        Server.manage_access(
          %ManageAccessRequest{
            assertion: root_t,
            op: :GRANT_ROLE,
            target_user_id: u.id,
            role: "owner"
          },
          nil
        )

      assert resp.status == :CALL_BAD_REQUEST
      assert Identity.roles_for(u.id) == []
    end

    test "AdminReadConversation requires a non-empty reason (break-glass accountability)" do
      {_root, root_t} = superadmin_assertion()
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

    test "ManageUser INVITE rejects an empty or duplicate login" do
      {_root, root_t} = superadmin_assertion()
      penta = provision("penta", "sub-penta")

      Server.manage_access(
        %ManageAccessRequest{
          assertion: root_t,
          op: :GRANT_ROLE,
          target_user_id: penta.id,
          role: "admin"
        },
        nil
      )

      t = assertion("sub-penta")

      assert Server.manage_user(%ManageUserRequest{assertion: t, op: :INVITE, login: ""}, nil).status ==
               :CALL_BAD_REQUEST

      # penta already exists as a login → duplicate
      assert Server.manage_user(
               %ManageUserRequest{assertion: t, op: :INVITE, login: "penta"},
               nil
             ).status == :CALL_BAD_REQUEST
    end
  end

  describe "dual-accept auth seam (legacy RPCs keep working)" do
    test "legacy_context in :dual passes a plaintext viewer through unchanged" do
      assert {:ok, %{viewer: "alice", scopes: ["group"]}} =
               Auth.legacy_context("alice", ["group"])
    end

    test "legacy_context in :dual verifies + derives a signed viewer (ignoring wire scopes)" do
      Identity.put_group_scopes("staff", ["public"])
      u = provision("penta", "sub-penta", ["staff"])
      t = assertion("sub-penta")
      # wire scopes claim [group,private] but the DERIVED scopes win
      assert {:ok, %{viewer: v, scopes: ["public"]}} =
               Auth.legacy_context(t, ["group", "private"])

      assert v == u.id
    end

    test "Ask still answers with a plaintext viewer (live channel unbroken)" do
      # empty corpus ⇒ NOT_FOUND, but the point is it does not crash on plaintext.
      resp = Server.ask(%AskRequest{query: "anything", scopes: ["public"], viewer: "alice"}, nil)
      assert resp.status in [:FOUND, :NOT_FOUND, :PARTIAL, :ERROR]
    end

    test "an assertion-shaped viewer that fails verification is NOT trusted as a plaintext id" do
      # a tampered/expired token (3 dot-segments) must fail closed to anonymous public,
      # not be treated as a literal viewer id (council: ghost-identity footgun).
      forged = "aaa.bbb.ccc"
      assert {:ok, %{viewer: "", scopes: ["public"]}} = Auth.legacy_context(forged, ["group"])
    end

    test ":strict rejects a plaintext viewer (the post-6b cutover posture)" do
      prev = Application.get_env(:swarm, :core_api)
      Application.put_env(:swarm, :core_api, Keyword.put(prev, :auth_mode, :strict))
      on_exit(fn -> Application.put_env(:swarm, :core_api, prev) end)

      assert Auth.legacy_context("alice", ["group"]) == {:error, :unauthenticated}
      # a signed assertion still resolves under strict
      provision("penta", "sub-penta")
      assert {:ok, %{}} = Auth.legacy_context(assertion("sub-penta"), [])
    end
  end
end
