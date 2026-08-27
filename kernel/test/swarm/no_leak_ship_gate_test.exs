defmodule Swarm.NoLeakShipGateTest do
  @moduledoc """
  Workspace ADR-16 step 8 — the adversarial per-user no-leak SHIP GATE. Treats
  "user A cannot read user B by ANY path" as a first-class property and attacks it
  across every kernel surface: the conversation module + its gRPC RPCs, break-glass,
  the corpus/graph read paths (search / neighborhood / activity), the RLS belt under
  connection-pool reuse, the service/anonymous identity, and audit-before-return.
  404-not-403 throughout (no existence oracle). The end-to-end-through-the-channel
  variant waits for 6b; the kernel side proven here IS the real guarantee.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Audit, Conversations, Core, Elevation, Identity, Person, Repo}

  alias Swarm.Core.{Auth, Server}
  alias Swarm.Graph.Store

  # The fixed source scope behind the "Internal" Project the default cohort (staff) is a
  # member of — the former `group` fixture (ADR-20: `src:<uuid>`, derived via Projects).
  @src Swarm.GraphCase.test_src()
  @sid "gate-sess"

  alias Swarm.Core.V1.{
    ActivityFeedRequest,
    AdminReadConversationRequest,
    DeliberationRequest,
    GetConversationRequest,
    ListConversationsRequest,
    LogConversationRequest,
    NeighborhoodRequest,
    SearchRequest
  }

  defp verdict do
    %{
      answer: "the answer",
      confidence: 0.9,
      disagreement: 0.1,
      panel: [%{model: "m1", answer: "PANEL-SECRET"}],
      judge: "j"
    }
  end

  setup do
    Swarm.GraphCase.truncate_graph()
    :ok
  end

  defp user(login) do
    {:ok, u} =
      Identity.upsert_from_claims(%{
        provider: "keycloak",
        subject: "sub-#{login}",
        login: login,
        groups: []
      })

    u
  end

  # A user who actually DERIVES a source scope (so a signed assertion resolves to
  # ["public", @src] — meaningful for testing that `private` data is excluded from a real
  # scoped read, not the trivial empty-scope case). Council (codex re-review). ADR-20: the
  # scope comes from an "Internal" Project whose member is the default cohort (staff).
  defp group_user(login) do
    unless Swarm.Projects.registered_scope?(@src) do
      register_source!(
        name: "Internal",
        id: String.replace_prefix(@src, "src:", ""),
        members: [%{group_id: "staff"}]
      )
    end

    {:ok, u} =
      Identity.upsert_from_claims(%{
        provider: "keycloak",
        subject: "sub-#{login}",
        login: login,
        groups: []
      })

    u
  end

  defp assertion(login), do: Actor.sign(%{"sub" => "sub-#{login}", "provider" => "keycloak"})

  # A local Wheel member with a LIVE elevation for session @sid: `{user, elevated_token}`.
  # Break-glass (`read_any_conversation`) exists only under such an elevation (ADR-20 D9).
  defp elevated_wheel do
    login = "root#{System.unique_integer([:positive])}"
    {:ok, u} = Identity.seed_wheel(%{id: Identity.uuid7(), login: login})

    proof =
      Actor.sign(
        %{
          "aud" => Actor.reauth_audience(),
          "sub" => login,
          "provider" => "local",
          "sid" => @sid,
          "jti" => "jti-#{System.unique_integer([:positive])}",
          "auth_time" => System.system_time(:second)
        },
        exp_in: 60
      )

    {:ok, _} = Elevation.request(%{uuid: u.id, sid: @sid}, "ship-gate", proof)
    {u, Actor.sign(%{"sub" => login, "provider" => "local", "sid" => @sid})}
  end

  describe "A cannot read B — the conversation module (every op)" do
    setup do
      alice = user("alice")
      bob = user("bob")
      {:ok, c} = Conversations.create(alice.id, %{title: "alice-only"})
      {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "SECRET-BODY"})
      %{alice: alice, bob: bob, c: c}
    end

    test "get / add_message / soft_delete of A's conversation by B ⇒ :not_found", %{
      bob: bob,
      c: c
    } do
      assert Conversations.get(bob.id, c.id) == :not_found
      assert Conversations.add_message(bob.id, c.id, %{role: "user", body: "x"}) == :not_found
      assert Conversations.soft_delete(bob.id, c.id) == :not_found
    end

    test "B's list never contains A's conversation", %{alice: alice, bob: bob} do
      {:ok, _} = Conversations.create(bob.id, %{title: "bob-only"})
      assert Conversations.list(bob.id) |> Enum.all?(&(&1.owner_id == bob.id))
      assert Conversations.list(alice.id) |> Enum.all?(&(&1.owner_id == alice.id))
    end

    test "co-members of the SAME Project cannot read each other's conversations (owner axis ⟂ scope)" do
      alice = group_user("alice2")
      bob = group_user("bob2")
      # positive control: BOTH derive the Project's source scope
      assert @src in Identity.scopes_for(alice.id) and @src in Identity.scopes_for(bob.id)
      {:ok, shared} = Conversations.create(alice.id, %{title: "shared?", scope: @src})
      assert {:ok, _} = Conversations.get(alice.id, shared.id)
      # bob shares the scope, not the conversation — owner axis is independent of scope
      assert Conversations.get(bob.id, shared.id) == :not_found
      refute Enum.any?(Conversations.list(bob.id), &(&1.id == shared.id))
    end
  end

  describe "A cannot read B — through the gRPC RPCs" do
    test "GetConversation / ListConversations / LogConversation with B's assertion" do
      user("alice")
      user("bob")

      log =
        Server.log_conversation(
          %LogConversationRequest{
            assertion: assertion("alice"),
            title: "a",
            role: "user",
            body: "hush"
          },
          nil
        )

      assert Server.get_conversation(
               %GetConversationRequest{
                 assertion: assertion("bob"),
                 conversation_id: log.conversation_id
               },
               nil
             ).status ==
               :CALL_NOT_FOUND

      assert Server.log_conversation(
               %LogConversationRequest{
                 assertion: assertion("bob"),
                 conversation_id: log.conversation_id,
                 role: "user",
                 body: "x"
               },
               nil
             ).status ==
               :CALL_NOT_FOUND

      assert Server.list_conversations(
               %ListConversationsRequest{assertion: assertion("bob")},
               nil
             ).conversations ==
               []
    end

    test "an anonymous / service identity (no assertion) cannot touch conversations" do
      user("alice")

      log =
        Server.log_conversation(
          %LogConversationRequest{
            assertion: assertion("alice"),
            title: "a",
            role: "user",
            body: "x"
          },
          nil
        )

      for a <- ["", "garbage", "not.a.jwt"] do
        assert Server.list_conversations(%ListConversationsRequest{assertion: a}, nil).status ==
                 :CALL_UNAUTHENTICATED

        assert Server.get_conversation(
                 %GetConversationRequest{assertion: a, conversation_id: log.conversation_id},
                 nil
               ).status ==
                 :CALL_UNAUTHENTICATED
      end
    end

    test "404-not-403: not-owned, non-existent, and malformed are indistinguishable" do
      user("bob")
      # non-existent and malformed both ⇒ NOT_FOUND for a valid actor
      assert Server.get_conversation(
               %GetConversationRequest{
                 assertion: assertion("bob"),
                 conversation_id: Identity.uuid7()
               },
               nil
             ).status ==
               :CALL_NOT_FOUND

      assert Server.get_conversation(
               %GetConversationRequest{
                 assertion: assertion("bob"),
                 conversation_id: "not-a-uuid"
               },
               nil
             ).status ==
               :CALL_NOT_FOUND
    end
  end

  describe "break-glass is elevation-only + audited-before-return" do
    test "a plain user cannot break-glass; an ELEVATED Wheel member can, and every attempt is audited" do
      alice = user("alice")
      bob = user("bob")
      {:ok, c} = Conversations.create(alice.id, %{title: "a"})
      {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "hush"})
      {root, root_t} = elevated_wheel()

      # plain user denied (audited), no data
      assert Server.admin_read_conversation(
               %AdminReadConversationRequest{
                 assertion: assertion("bob"),
                 conversation_id: c.id,
                 reason: "peek"
               },
               nil
             ).status ==
               :CALL_NOT_AUTHORIZED

      assert Enum.any?(Audit.for_actor(bob.id), &(&1.decision == "denied"))

      # the Wheel member's COLD session (no elevation) is denied too — audited
      cold =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: Actor.sign(%{"sub" => root.login, "provider" => "local", "sid" => "cold"}),
            conversation_id: c.id,
            reason: "peek"
          },
          nil
        )

      assert cold.status == :CALL_NOT_AUTHORIZED

      # elevated session allowed, audited allowed + data_returned true, BEFORE data returned
      ok =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: root_t,
            conversation_id: c.id,
            reason: "ticket-9"
          },
          nil
        )

      assert ok.status == :CALL_OK
      [row | _] = Audit.for_actor(root.id) |> Enum.filter(&(&1.action == "read_conversation"))
      assert row.decision == "allowed" and row.data_returned == true
      assert row.target_conversation_id == c.id
    end
  end

  describe "an elevation is not an ambient read path (ADR-20 D10)" do
    test "an ELEVATED session reads no foreign conversation except through audited break-glass" do
      alice = user("alice")
      {:ok, c} = Conversations.create(alice.id, %{title: "a"})
      {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "hush"})
      {root, root_t} = elevated_wheel()

      assert Conversations.get(root.id, c.id) == :not_found
      assert Conversations.list(root.id) == []

      assert Server.get_conversation(
               %GetConversationRequest{assertion: root_t, conversation_id: c.id},
               nil
             ).status == :CALL_NOT_FOUND

      assert Server.list_conversations(%ListConversationsRequest{assertion: root_t}, nil).conversations ==
               []

      # positive control: the SAME session can break-glass — reason required, audited
      ok =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: root_t,
            conversation_id: c.id,
            reason: "ticket"
          },
          nil
        )

      assert ok.status == :CALL_OK
      assert Enum.any?(Audit.for_actor(root.id), &(&1.action == "read_conversation"))
    end
  end

  describe "conversations are unreachable from the corpus / graph read paths" do
    test "a conversation body never surfaces via KbSearch/Core.search at ANY scope" do
      alice = user("alice")
      {:ok, c} = Conversations.create(alice.id, %{title: "NEEDLEHAYSTACK"})

      {:ok, _} =
        Conversations.add_message(alice.id, c.id, %{role: "user", body: "NEEDLEHAYSTACK body"})

      # POSITIVE CONTROL (de-vacuous, architect review): the same needle seeded as a
      # graph node IS findable — so an empty result below is exclusion, not a dead
      # search path returning [] by construction.
      Store.upsert_node("concept", "NEEDLEHAYSTACK corpus page", scope: @src)
      control = Core.search("NEEDLEHAYSTACK", [@src], limit: 20)
      assert Enum.map(control, & &1.key) == ["NEEDLEHAYSTACK corpus page"]

      # the conversation title/body itself never surfaces at any scope — every hit
      # is the control node, never conversation-derived
      for scope <- [["public"], [@src], ["private"], ["public", @src, "private"]] do
        keys = Core.search("NEEDLEHAYSTACK", scope, limit: 20) |> Enum.map(& &1.key)
        assert keys -- ["NEEDLEHAYSTACK corpus page"] == []
      end
    end
  end

  describe "person chat-derived facts respect the leak rule (service/enrichment identity)" do
    test "a chat-derived person fact is invisible where the same fact via corpus is visible" do
      alice = user("alice")
      :ok = Person.record_chat_fact(alice.id, "based_in", "concept", "QwertyChatSecret")

      # POSITIVE CONTROL: an equivalent fact arriving through the ORDINARY corpus
      # path at group scope IS found — proving the exclusion below is the private
      # pin doing its job, not the query missing both.
      Store.upsert_node("concept", "QwertyChatSecret corpus twin", scope: @src)

      keys = Core.search("QwertyChatSecret", ["public", @src], limit: 20) |> Enum.map(& &1.key)
      assert "QwertyChatSecret corpus twin" in keys
      refute "QwertyChatSecret" in keys
    end
  end

  describe "private is not derivable — the person-scope leak-guard" do
    test "no Project membership can ever confer private; reads with derived scopes stay excluded" do
      alice = user("alice")
      :ok = Person.record_chat_fact(alice.id, "based_in", "concept", "XkcdChatSecret")

      # ADR-20: the only derivation path is Project → Source → `src:<uuid>`; a Source's scope
      # is minted from its id, so `private` cannot be registered, granted or derived. Groups
      # grant no scopes at all (the old grant boundary is gone, rejected + audited).
      eve = group_user("eve")
      derived = Identity.scopes_for(eve.id)
      assert Enum.sort(derived) == Enum.sort(["public", @src])
      refute "private" in derived
      refute Swarm.Projects.registered_scope?("private")

      assert {:error, :group_scopes_forbidden} =
               Swarm.Admin.set_group_scopes(eve.id, "staff", ["private"])

      # and a read with exactly the derived scopes cannot see the chat fact
      assert Core.search("XkcdChatSecret", derived, limit: 20) == []
    end

    test "a plaintext dual-mode caller cannot REQUEST private via wire scopes" do
      # Under :dual a legacy plaintext viewer is trusted — but the wire scopes are
      # clamped (council codex): asking for private yields a context without it.
      # `:dual` is now an explicit opt-in (default flipped to :strict, dual-mode-history-leak).
      prev = Application.get_env(:swarm, :core_api)
      Application.put_env(:swarm, :core_api, Keyword.put(prev, :auth_mode, :dual))
      on_exit(fn -> Application.put_env(:swarm, :core_api, prev) end)

      assert {:ok, ctx} = Auth.legacy_context("mallory", [@src, "private"])
      refute "private" in ctx.scopes

      # private-only collapses to [] — fail-closed, sees nothing
      assert {:ok, %{scopes: []}} = Auth.legacy_context("mallory", ["private"])
    end
  end

  describe "Deliberation (ADR-15 retained panel) is owner-private too" do
    test "the owner CAN read their own deliberation (positive control)" do
      alice = group_user("alice")
      ref = Swarm.Deliberation.maybe_persist(verdict(), alice.id, [@src])
      assert ref != ""

      own =
        Server.deliberation(
          %DeliberationRequest{ask_ref: ref, viewer: assertion("alice"), scopes: [@src]},
          nil
        )

      assert own.status == :FOUND
      assert own.answer == "the answer"
    end

    test "B cannot read A's deliberation; :strict closes the plaintext-viewer path" do
      alice = user("alice")
      user("bob")
      ref = Swarm.Deliberation.maybe_persist(verdict(), alice.id, [@src])
      assert ref != ""

      # B, with B's own SIGNED assertion, resolves to B ⇒ not the owner ⇒ NOT_FOUND
      bob_view =
        Server.deliberation(
          %DeliberationRequest{ask_ref: ref, viewer: assertion("bob"), scopes: [@src]},
          nil
        )

      assert bob_view.status == :NOT_FOUND

      # Under :dual (default) a LEGACY plaintext viewer is still trusted (the ADR-7
      # residual, closed by 6b) — so assert the :strict posture on the ACTUAL RPC: a
      # plaintext viewer=alice can no longer impersonate her.
      prev = Application.get_env(:swarm, :core_api)
      Application.put_env(:swarm, :core_api, Keyword.put(prev, :auth_mode, :strict))
      on_exit(fn -> Application.put_env(:swarm, :core_api, prev) end)

      spoof =
        Server.deliberation(
          %DeliberationRequest{ask_ref: ref, viewer: alice.id, scopes: [@src]},
          nil
        )

      assert spoof.status == :NOT_FOUND
    end
  end

  describe "person chat-facts do not leak via Neighborhood or ActivityFeed" do
    test "a real group-scoped viewer cannot center Neighborhood on a private person node" do
      # alice genuinely holds `group` (derived from her group) — so this proves the
      # PRIVATE center is excluded from a real group read, not the empty-scope case.
      alice = group_user("alice")
      assert {:ok, %{scopes: scopes}} = Auth.legacy_context(assertion("alice"), [])
      assert @src in scopes
      :ok = Person.record_chat_fact(alice.id, "based_in", "concept", "NborSecret")
      person_id = Person.node_id(alice.id)

      resp =
        Server.neighborhood(
          %NeighborhoodRequest{node_id: person_id, scopes: [@src], viewer: assertion("alice")},
          nil
        )

      # the person node is private ⇒ not visible to a group scope ⇒ NOT_FOUND
      assert resp.status == :NOT_FOUND
    end

    test "a real group ActivityFeed carries the group event but never the private one" do
      alice = group_user("alice")

      # POSITIVE CONTROL first (de-vacuous, architect review): a GROUP-scoped edge
      # write emits an outbox event that IS delivered to a group viewer — so the
      # exclusion below is scope-filtering, not an empty/unwired feed.
      a = Store.upsert_node("article", "act-a", scope: @src)
      b = Store.upsert_node("concept", "act-b", scope: @src)
      {:ok, _} = Store.add_edge(a, b, "mentions", "act-ev-1", scope: @src)

      # the private chat-derived fact also writes an edge (private) — must be dropped
      :ok = Person.record_chat_fact(alice.id, "works_on", "concept", "ActSecret")

      resp =
        Server.activity_feed(
          %ActivityFeedRequest{scopes: [@src], viewer: assertion("alice")},
          nil
        )

      # falsifiable: the feed is non-empty and contains EXACTLY the one group edge
      # event; a leak of the private chat edge would make it two.
      assert resp.status == :FOUND
      reinforced = Enum.filter(resp.events, &(&1.kind == "edge_reinforced"))
      assert length(reinforced) == 1
    end
  end

  describe "KbSearch through the gRPC wire (dual-accept scope derivation)" do
    test "a signed assertion's DERIVED scopes replace the wire scopes entirely" do
      alice = group_user("alice")

      # bob is NOT in the cohort that holds the Internal Project (ADR-20: no membership ⇒ public only)
      bob = user("bob")
      :ok = Identity.remove_from_group(bob.id, "staff")
      Store.upsert_node("concept", "WireGroupFact", scope: @src)
      :ok = Person.record_chat_fact(alice.id, "works_on", "concept", "WirePrivFact")

      # alice signs; her wire scopes CLAIM public-only — but derivation wins and her
      # real group grant surfaces the group fact (proves the wire scopes are ignored)
      hits =
        Server.kb_search(
          %SearchRequest{
            query: "WireGroupFact",
            assertion: assertion("alice"),
            scopes: ["public"]
          },
          nil
        ).hits

      assert Enum.map(hits, & &1.key) == ["WireGroupFact"]

      # bob (no groups) signs and CLAIMS group+private on the wire — derivation
      # yields [] and the spoof sees neither the group fact nor the private one
      for q <- ["WireGroupFact", "WirePrivFact"] do
        spoof =
          Server.kb_search(
            %SearchRequest{
              query: q,
              assertion: assertion("bob"),
              scopes: [@src, "private"]
            },
            nil
          )

        assert spoof.hits == []
      end
    end
  end

  describe "break-glass: no existence oracle + every outcome audited" do
    test "a plain user gets NOT_AUTHORIZED for existing AND non-existent (no oracle), both audited" do
      alice = user("alice")
      bob = user("bob")
      {:ok, c} = Conversations.create(alice.id, %{title: "a"})

      existing =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: assertion("bob"),
            conversation_id: c.id,
            reason: "x"
          },
          nil
        )

      ghost =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: assertion("bob"),
            conversation_id: Identity.uuid7(),
            reason: "x"
          },
          nil
        )

      # identical outcome ⇒ a non-superadmin cannot distinguish real from fake ids
      assert existing.status == :CALL_NOT_AUTHORIZED
      assert ghost.status == :CALL_NOT_AUTHORIZED
      assert length(Audit.for_actor(bob.id)) == 2
    end

    test "an elevated break-glass on a non-existent conversation ⇒ NOT_FOUND, still audited" do
      {root, root_t} = elevated_wheel()

      resp =
        Server.admin_read_conversation(
          %AdminReadConversationRequest{
            assertion: root_t,
            conversation_id: Identity.uuid7(),
            reason: "scan?"
          },
          nil
        )

      assert resp.status == :CALL_NOT_FOUND
      assert Enum.any?(Audit.for_actor(root.id), &(&1.decision == "not_found"))
    end

    test "a malformed conversation id at the break-glass RPC never 500s (no cast oracle)" do
      user("bob")
      {root, root_t} = elevated_wheel()

      # plain user: cap check first ⇒ NOT_AUTHORIZED (no existence/format oracle)
      assert Server.admin_read_conversation(
               %AdminReadConversationRequest{
                 assertion: assertion("bob"),
                 conversation_id: "not-a-uuid",
                 reason: "x"
               },
               nil
             ).status == :CALL_NOT_AUTHORIZED

      # elevated: malformed id ⇒ NOT_FOUND (validated before the store; no 500), audited
      assert Server.admin_read_conversation(
               %AdminReadConversationRequest{
                 assertion: root_t,
                 conversation_id: "not-a-uuid",
                 reason: "x"
               },
               nil
             ).status == :CALL_NOT_FOUND

      assert Enum.any?(Audit.for_actor(root.id), &(&1.decision == "not_found"))
    end
  end

  describe "audit-BEFORE-return ordering (D6) is structural, not incidental" do
    test "admin_read refuses to run inside a caller transaction (audit durability guard)" do
      alice = user("alice")
      {root, _t} = elevated_wheel()
      {:ok, c} = Conversations.create(alice.id, %{title: "a"})

      # A caller transaction could roll the audit row back AFTER the data was read —
      # exactly the hole D6 forbids. The guard makes that shape impossible.
      assert_raise RuntimeError, ~r/must not run inside a transaction/, fn ->
        Repo.transaction(fn ->
          Conversations.admin_read({root.id, @sid}, c.id, "peek")
        end)
      end
    end

    test "the audit row is durably committed before the data returns (separate connection)" do
      alice = user("alice")
      {root, _t} = elevated_wheel()
      {:ok, c} = Conversations.create(alice.id, %{title: "a"})
      {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "hush"})

      assert {:ok, _} = Conversations.admin_read({root.id, @sid}, c.id, "incident-42")

      # Visible from a COMPLETELY separate Postgres connection ⇒ the audit commit is
      # its own durable transaction, not pending state a caller could still discard.
      {:ok, conn} = Postgrex.start_link(Swarm.Repo.config())

      %{rows: [[n]]} =
        Postgrex.query!(
          conn,
          "SELECT count(*) FROM admin_action_audit WHERE reason = 'incident-42' AND decision = 'allowed' AND data_returned",
          []
        )

      GenServer.stop(conn)
      assert n == 1
    end
  end

  # HONEST SCOPE (architect review): this describe proves (a) our choke-point's GUC
  # hygiene on a live connection and (b) that the RLS POLICY bites under a
  # purpose-made NOSUPERUSER role. It does NOT prove the shipped posture — the
  # deployed kernel still connects as a superuser role where RLS is dormant; making
  # the belt live on the real connection is `board/todo/rls-app-role`.
  describe "RLS belt holds under connection-pool reuse (no GUC bleed)" do
    test "the REAL Conversations choke-point leaves no app.current_user on the connection" do
      # Council (gemini): test OUR code, not Postgres. Call the real Conversations
      # functions (they go through with_owner), then on the SAME connection (an
      # enclosing transaction) read the GUC: with_owner must have set AND cleared it,
      # so nothing later can inherit alice's identity. A regression (session-level
      # set_config, or a missing clear) fails here.
      alice = user("alice")

      {:ok, :ok} =
        Repo.transaction(fn ->
          {:ok, c} = Conversations.create(alice.id, %{title: "a"})
          {:ok, _} = Conversations.get(alice.id, c.id)
          [[leaked]] = Repo.query!("SELECT current_setting('app.current_user', true)").rows
          assert leaked in [nil, ""]
          :ok
        end)
    end

    test "interleaved owners: a raw non-superuser read only ever sees the current owner / fails closed" do
      alice = user("alice")
      bob = user("bob")
      {:ok, _} = Conversations.create(alice.id, %{title: "a"})
      {:ok, _} = Conversations.create(bob.id, %{title: "b"})

      # After the choke-point ops committed and connections returned to the pool, a
      # fresh transaction under the REAL runtime app role (rls-app-role migration:
      # NOSUPERUSER NOBYPASSRLS) with GUC=alice sees ONLY alice; with no GUC (a
      # leaked/forgotten context) sees NOTHING — the transaction-local GUC never
      # bleeds across pooled checkouts.
      {:ok, alice_rows} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_app")
          Repo.query!("SELECT set_config('app.current_user', $1, true)", [alice.id])
          Repo.query!("SELECT owner_id FROM conversation").rows
        end)

      assert alice_rows |> List.flatten() |> Enum.map(&Ecto.UUID.load!/1) |> Enum.uniq() == [
               alice.id
             ]

      {:ok, no_ctx_rows} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_app")
          Repo.query!("SELECT owner_id FROM conversation").rows
        end)

      assert no_ctx_rows == []
    end
  end

  describe "the swarm_app runtime role posture (rls-app-role)" do
    test "the role is NOSUPERUSER NOBYPASSRLS and the audit table is append-only for it" do
      %{rows: [[super?, bypass?]]} =
        Repo.query!("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'swarm_app'")

      refute super?
      refute bypass?

      alice = user("alice")
      {root, _t} = elevated_wheel()
      {:ok, c} = Conversations.create(alice.id, %{title: "a"})
      {:ok, _} = Conversations.admin_read({root.id, @sid}, c.id, "audit-belt-probe")

      # UPDATE / DELETE / TRUNCATE on the audit trail are DENIED at the DB for the
      # runtime role — tampering with break-glass evidence needs the privileged role.
      for sql <- [
            "UPDATE admin_action_audit SET decision = 'denied'",
            "DELETE FROM admin_action_audit",
            "TRUNCATE admin_action_audit"
          ] do
        {:error, _} =
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL ROLE swarm_app")

            case Repo.query(sql) do
              {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
                Repo.rollback(:denied_as_expected)

              other ->
                flunk("audit mutation was not denied: #{inspect(other)}")
            end
          end)
      end
    end

    test "the SECURITY DEFINER owner lookup works under the app role where a raw read dies" do
      alice = user("alice")
      {:ok, c} = Conversations.create(alice.id, %{title: "a"})

      {:ok, {raw_rows, looked_up}} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_app")
          # no app.current_user GUC set: RLS filters the raw read to nothing…
          raw =
            Repo.query!("SELECT owner_id FROM conversation WHERE id = $1", [Ecto.UUID.dump!(c.id)]).rows

          # …but the hardened SECURITY DEFINER lookup (the break-glass bootstrap)
          # still finds the owner — impersonation stays possible under live RLS.
          %{rows: [[owner]]} =
            Repo.query!("SELECT public.conversation_owner_lookup($1)", [Ecto.UUID.dump!(c.id)])

          {raw, owner}
        end)

      assert raw_rows == []
      assert Ecto.UUID.load!(looked_up) == alice.id
    end

    test "representative kernel DML works under the app role (missing-grant detector)" do
      alice = user("alice")

      {:ok, :ok} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_app")
          # graph write path (node + edge + outbox + provenance)
          a = Store.upsert_node("article", "app-role-a", scope: @src)
          b = Store.upsert_node("concept", "app-role-b", scope: @src)
          {:ok, _} = Store.add_edge(a, b, "mentions", "app-role-ev", scope: @src)
          # conversation choke-point path (RLS live for this role)
          {:ok, c} = Conversations.create(alice.id, %{title: "app-role"})
          {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "x"})
          {:ok, got} = Conversations.get(alice.id, c.id)
          assert got.conversation.id == c.id
          # identity read path
          assert Identity.scopes_for(alice.id) == ["public"]
          :ok
        end)
    end
  end

  describe "the strict-cutover posture (6b) closes the plaintext path" do
    test "under :strict a plaintext viewer is rejected; a signed one still resolves" do
      prev = Application.get_env(:swarm, :core_api)
      Application.put_env(:swarm, :core_api, Keyword.put(prev, :auth_mode, :strict))
      on_exit(fn -> Application.put_env(:swarm, :core_api, prev) end)

      user("alice")
      assert Auth.legacy_context("alice", [@src, "private"]) == {:error, :unauthenticated}
      assert {:ok, %{}} = Auth.legacy_context(assertion("alice"), [])
    end
  end
end
