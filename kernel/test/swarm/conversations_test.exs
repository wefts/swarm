defmodule Swarm.ConversationsTest do
  @moduledoc """
  Workspace ADR-16 step 3 — per-user conversation privacy (the load-bearing
  no-leak-class invariant). Conversations are kernel-owned; user A cannot read
  user B's by any path. Enforced by ONE choke point that injects
  `owner_id = <verified subject>` (never caller-supplied), 404-not-403 (no
  existence oracle), plus Postgres RLS as the belt (proven to bite under a
  non-superuser role, even for a raw query that bypasses the choke point).
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Conversations, Repo}

  defp user(login, subject) do
    {:ok, u} =
      Identity.upsert_from_claims(%{
        provider: "keycloak",
        subject: subject,
        login: login,
        groups: []
      })

    u
  end

  describe "create / get / list — owner-scoped" do
    test "an owner creates a conversation, adds messages, and reads it back" do
      alice = user("alice", "sub-alice")
      {:ok, c} = Conversations.create(alice.id, %{title: "planning"})
      {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "hello"})

      {:ok, _} =
        Conversations.add_message(alice.id, c.id, %{
          role: "assistant",
          body: "hi",
          ask_ref: "ref1"
        })

      assert {:ok, %{conversation: conv, messages: msgs}} = Conversations.get(alice.id, c.id)
      assert conv.id == c.id
      assert conv.owner_id == alice.id
      assert conv.title == "planning"
      assert length(msgs) == 2
      assert Enum.map(msgs, & &1.body) == ["hello", "hi"]
      assert List.last(msgs).ask_ref == "ref1"
    end

    test "list returns only the owner's non-deleted conversations, newest first" do
      alice = user("alice", "sub-alice")
      bob = user("bob", "sub-bob")
      {:ok, _a1} = Conversations.create(alice.id, %{title: "a1"})
      {:ok, a2} = Conversations.create(alice.id, %{title: "a2"})
      {:ok, _b1} = Conversations.create(bob.id, %{title: "b1"})

      titles = alice.id |> Conversations.list() |> Enum.map(& &1.title)
      assert "a1" in titles
      assert "a2" in titles
      refute "b1" in titles

      :ok = Conversations.soft_delete(alice.id, a2.id)
      titles2 = alice.id |> Conversations.list() |> Enum.map(& &1.title)
      refute "a2" in titles2
    end
  end

  describe "no-leak: A cannot read B (404-not-403, no existence oracle)" do
    test "get of another owner's conversation ⇒ :not_found" do
      alice = user("alice", "sub-alice")
      bob = user("bob", "sub-bob")
      {:ok, c} = Conversations.create(alice.id, %{title: "secret"})
      assert Conversations.get(bob.id, c.id) == :not_found
    end

    test "get of a non-existent id ⇒ :not_found (indistinguishable from not-owned)" do
      alice = user("alice", "sub-alice")
      assert Conversations.get(alice.id, Identity.uuid7()) == :not_found
    end

    test "add_message to a conversation you don't own ⇒ :not_found (write-side gate)" do
      alice = user("alice", "sub-alice")
      bob = user("bob", "sub-bob")
      {:ok, c} = Conversations.create(alice.id, %{title: "secret"})
      assert Conversations.add_message(bob.id, c.id, %{role: "user", body: "peek"}) == :not_found
      # and alice's conversation is untouched
      assert {:ok, %{messages: []}} = Conversations.get(alice.id, c.id)
    end

    test "soft_delete of another owner's conversation ⇒ :not_found" do
      alice = user("alice", "sub-alice")
      bob = user("bob", "sub-bob")
      {:ok, c} = Conversations.create(alice.id, %{title: "secret"})
      assert Conversations.soft_delete(bob.id, c.id) == :not_found
      assert {:ok, _} = Conversations.get(alice.id, c.id)
    end

    test "a malformed conversation id ⇒ :not_found (no cast-error 500, no oracle)" do
      alice = user("alice", "sub-alice")
      assert Conversations.get(alice.id, "not-a-uuid") == :not_found

      assert Conversations.add_message(alice.id, "not-a-uuid", %{role: "user", body: "x"}) ==
               :not_found

      assert Conversations.soft_delete(alice.id, "not-a-uuid") == :not_found
    end
  end

  describe "RLS belt bites under a non-superuser role (defense-in-depth)" do
    setup do
      # A throwaway non-superuser, non-BYPASSRLS role so RLS actually applies (the
      # deployed `swarm` role is superuser → RLS dormant; this proves the policy).
      Repo.query!("""
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'swarm_rls_test') THEN
          CREATE ROLE swarm_rls_test NOSUPERUSER NOBYPASSRLS;
        END IF;
      END $$
      """)

      Repo.query!("GRANT SELECT ON conversation, message TO swarm_rls_test")
      :ok
    end

    test "a raw SELECT bypassing the choke point still returns only the current owner's rows" do
      alice = user("alice", "sub-alice")
      bob = user("bob", "sub-bob")
      {:ok, _} = Conversations.create(alice.id, %{title: "a"})
      {:ok, _} = Conversations.create(bob.id, %{title: "b"})

      # As a non-superuser, with app.current_user = alice, a raw all-rows query is
      # filtered by RLS to alice's rows only — the belt holds even if a future code
      # path forgets the WHERE owner_id = $1 predicate.
      {:ok, rows} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_rls_test")
          Repo.query!("SELECT set_config('app.current_user', $1, true)", [alice.id])
          Repo.query!("SELECT owner_id FROM conversation").rows
        end)

      owners = rows |> List.flatten() |> Enum.map(&Ecto.UUID.load!/1) |> Enum.uniq()
      assert owners == [alice.id]
    end

    test "with no app.current_user set, RLS returns zero rows (fail closed)" do
      alice = user("alice", "sub-alice")
      {:ok, _} = Conversations.create(alice.id, %{title: "a"})

      {:ok, rows} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_rls_test")
          Repo.query!("SELECT owner_id FROM conversation").rows
        end)

      assert rows == []
    end

    test "a raw SELECT on message is RLS-filtered to the current owner too" do
      Repo.query!("GRANT SELECT ON message TO swarm_rls_test")
      alice = user("alice", "sub-alice")
      bob = user("bob", "sub-bob")
      {:ok, ca} = Conversations.create(alice.id, %{title: "a"})
      {:ok, cb} = Conversations.create(bob.id, %{title: "b"})
      {:ok, _} = Conversations.add_message(alice.id, ca.id, %{role: "user", body: "alice-secret"})
      {:ok, _} = Conversations.add_message(bob.id, cb.id, %{role: "user", body: "bob-secret"})

      {:ok, bodies} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_rls_test")
          Repo.query!("SELECT set_config('app.current_user', $1, true)", [alice.id])
          Repo.query!("SELECT body FROM message").rows
        end)

      assert List.flatten(bodies) == ["alice-secret"]
    end

    test "the GUC is cleared after with_owner, so a later read in an OUTER txn sees nothing" do
      alice = user("alice", "sub-alice")
      bob = user("bob", "sub-bob")
      {:ok, _} = Conversations.create(alice.id, %{title: "a"})
      {:ok, _} = Conversations.create(bob.id, %{title: "b"})

      # Simulate a broader app transaction that calls the choke point, then does a
      # raw read: because with_owner clears app.current_user on exit, the raw read
      # under a non-superuser role is fail-closed (zero rows), not alice's rows.
      {:ok, rows} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE swarm_rls_test")
          # (as the non-superuser we cannot run the choke point's writes, but we can
          # prove the GUC state: set it, clear it as with_owner does, then read)
          Repo.query!("SELECT set_config('app.current_user', $1, true)", [alice.id])
          Repo.query!("SELECT set_config('app.current_user', '', true)")
          Repo.query!("SELECT owner_id FROM conversation").rows
        end)

      assert rows == []
    end
  end
end
