defmodule Swarm.AdminBreakGlassTest do
  @moduledoc """
  Workspace ADR-16 step 4 (Decision 6) — admin break-glass conversation read.
  NOT an all-rows query: the superadmin *impersonates the target's view* through the
  SAME owner predicate (setting the choke point's owner to the conversation's owner),
  gated by the `read_any_conversation` capability, with an immutable audit row written
  BEFORE any data is returned. A non-superadmin cannot use it.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Audit, Conversations}

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

  defp superadmin do
    {:ok, u} = Identity.seed_superadmin(%{id: Identity.uuid7(), login: "root"})
    u.id
  end

  test "a superadmin reads another user's conversation via impersonation, audited-before-return" do
    root = superadmin()
    bob = user("bob", "sub-bob")
    {:ok, c} = Conversations.create(bob.id, %{title: "bob-secret"})
    {:ok, _} = Conversations.add_message(bob.id, c.id, %{role: "user", body: "hush"})

    assert {:ok, %{conversation: conv, messages: msgs}} =
             Conversations.admin_read(root, c.id, "support ticket 42")

    assert conv.id == c.id
    assert conv.owner_id == bob.id
    assert Enum.map(msgs, & &1.body) == ["hush"]

    # exactly one audit row, decision allowed, data_returned true, target recorded
    [row] = Audit.for_actor(root)
    assert row.action == "read_conversation"
    assert row.decision == "allowed"
    assert row.data_returned == true
    assert row.target_conversation_id == c.id
    assert row.target_user_id == bob.id
    assert row.reason == "support ticket 42"
  end

  test "a non-superadmin is denied (no cap), no data, and the target is recorded for forensics" do
    mallory = user("mallory", "sub-mallory")
    bob = user("bob", "sub-bob")
    {:ok, c} = Conversations.create(bob.id, %{title: "bob-secret"})

    assert Conversations.admin_read(mallory.id, c.id, "curious") == :not_authorized
    # the denied attempt is itself audited (privilege-abuse detection), no data returned,
    # and the attempted target is preserved (council: gemini)
    [row] = Audit.for_actor(mallory.id)
    assert row.decision == "denied"
    assert row.data_returned == false
    assert row.target_conversation_id == c.id
  end

  test "break-glass on a non-existent conversation ⇒ :not_found, audited (no data)" do
    root = superadmin()
    assert Conversations.admin_read(root, Identity.uuid7(), "typo") == :not_found
    [row] = Audit.for_actor(root)
    assert row.decision == "not_found"
    assert row.data_returned == false
  end

  test "break-glass on a malformed id ⇒ :not_found (no cast-500), audited" do
    root = superadmin()
    assert Conversations.admin_read(root, "not-a-uuid", nil) == :not_found
    assert [%{decision: "not_found"}] = Audit.for_actor(root)
  end

  test "a plain admin (not superadmin) cannot break-glass — read_any_conversation is superadmin-only" do
    # grant only the `admin` role → caps exclude read_any_conversation
    u = user("adminuser", "sub-admin")

    Swarm.Repo.query!(
      "INSERT INTO role_grant (user_id, role, source) VALUES ($1, 'admin', 'direct')",
      [Ecto.UUID.dump!(u.id)]
    )

    bob = user("bob", "sub-bob")
    {:ok, c} = Conversations.create(bob.id, %{title: "x"})
    assert Conversations.admin_read(u.id, c.id, "nope") == :not_authorized
  end
end
