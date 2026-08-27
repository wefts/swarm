defmodule Swarm.AdminBreakGlassTest do
  @moduledoc """
  Workspace ADR-16 step 4 (Decision 6) + ADR-20 — admin break-glass conversation read.
  NOT an all-rows query: the actor *impersonates the target's view* through the SAME owner
  predicate (setting the choke point's owner to the conversation's owner), gated by the
  `read_any_conversation` capability — which exists ONLY under a live, session-bound
  elevation of a local Wheel member — with an immutable audit row written BEFORE any data
  is returned. An admin, an unelevated Wheel member, or the same Wheel member from another
  session cannot use it.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Audit, Conversations, Elevation}

  @sid "bg-sess"

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

  # An ELEVATED Wheel member as the actor ref `{uuid, sid}` (+ the bare uuid for audits).
  defp elevated do
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

    {:ok, _} = Elevation.request(%{uuid: u.id, sid: @sid}, "support", proof)
    {u.id, @sid}
  end

  defp read_rows(uuid),
    do: Audit.for_actor(uuid) |> Enum.filter(&(&1.action == "read_conversation"))

  test "an elevated Wheel member reads another user's conversation via impersonation, audited-before-return" do
    {root_id, _} = root = elevated()
    bob = user("bob", "sub-bob")
    {:ok, c} = Conversations.create(bob.id, %{title: "bob-secret"})
    {:ok, _} = Conversations.add_message(bob.id, c.id, %{role: "user", body: "hush"})

    assert {:ok, %{conversation: conv, messages: msgs}} =
             Conversations.admin_read(root, c.id, "support ticket 42")

    assert conv.id == c.id
    assert conv.owner_id == bob.id
    assert Enum.map(msgs, & &1.body) == ["hush"]

    # exactly one read audit row, decision allowed, data_returned true, target recorded
    [row] = read_rows(root_id)
    assert row.decision == "allowed"
    assert row.data_returned == true
    assert row.target_conversation_id == c.id
    assert row.target_user_id == bob.id
    assert row.reason == "support ticket 42"
  end

  test "a non-elevated actor is denied (no cap), no data, and the target is recorded for forensics" do
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
    {root_id, _} = root = elevated()
    assert Conversations.admin_read(root, Identity.uuid7(), "typo") == :not_found
    [row] = read_rows(root_id)
    assert row.decision == "not_found"
    assert row.data_returned == false
  end

  test "break-glass on a malformed id ⇒ :not_found (no cast-500), audited" do
    {root_id, _} = root = elevated()
    assert Conversations.admin_read(root, "not-a-uuid", nil) == :not_found
    assert [%{decision: "not_found"}] = read_rows(root_id)
  end

  test "an admin cannot break-glass; neither can a Wheel member without an elevation or from another session" do
    admin = user("adminuser", "sub-admin")
    :ok = Identity.add_to_group(admin.id, "admins")
    bob = user("bob", "sub-bob")
    {:ok, c} = Conversations.create(bob.id, %{title: "x"})
    assert Conversations.admin_read(admin.id, c.id, "nope") == :not_authorized

    {root_id, sid} = elevated()
    # bare uuid (no session) and a different session are NOT elevated
    assert Conversations.admin_read(root_id, c.id, "nope") == :not_authorized
    assert Conversations.admin_read({root_id, "other-session"}, c.id, "nope") == :not_authorized
    assert {:ok, _} = Conversations.admin_read({root_id, sid}, c.id, "yes")
  end
end
