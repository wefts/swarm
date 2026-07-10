defmodule Swarm.PersonTest do
  @moduledoc """
  Workspace ADR-16 step 7 — the person-as-data projection (P5, feeds item 3). A user
  is projected as a graph `user` node keyed by their uuid; facts about them hang off
  as claim-edges. The **leak rule**: facts DERIVED FROM CHAT are forced to `private`
  scope so a scoped corpus read (public/group) can never surface them. Deleting the
  account anonymizes the person node (detach, never dangle) while learned content
  persists (D11).
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Admin, Core, Identity, Person}
  alias Swarm.Graph.Store

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

  describe "project/1" do
    test "projects a user node keyed by the uuid, idempotently" do
      u = user("penta")
      id = Person.project(u.id)
      assert is_integer(id)
      # keyed by uuid, type user
      assert Person.node_id(u.id) == id
      # idempotent — a second projection resolves to the same node
      assert Person.project(u.id) == id
    end

    test "person nodes are pinned private — the contract refuses any wider write" do
      u = user("penta")
      Person.project(u.id)
      assert person_scope(u.id) == "private"

      # no path — Person or raw Store — can mint/widen a person node beyond private
      assert_raise Swarm.Graph.ContractError, fn ->
        Store.upsert_node("user", u.id, scope: "group")
      end
    end
  end

  describe "the leak rule — chat-derived facts never surface to scoped corpus reads" do
    test "a chat-derived fact is private and excluded from a group read; a corpus fact is not" do
      alice = user("alice")
      # a fact learned from alice's private chat
      :ok = Person.record_chat_fact(alice.id, "based_in", "concept", "Zzyzx-chat-secret")
      # a fact that legitimately lives in the group corpus
      Store.upsert_node("concept", "Zzyzx-corpus-public", scope: "group")

      keys = Core.search("Zzyzx", ["group"], limit: 10) |> Enum.map(& &1.key)
      assert "Zzyzx-corpus-public" in keys
      refute "Zzyzx-chat-secret" in keys
    end

    test "the chat-derived object node + edge are stored at private scope" do
      alice = user("alice")
      :ok = Person.record_chat_fact(alice.id, "works_on", "concept", "ProjectX-secret")

      [[scope]] =
        Swarm.Repo.query!("SELECT scope FROM node WHERE type='concept' AND key='ProjectX-secret'").rows

      assert scope == "private"
    end
  end

  describe "anonymize/1 (orphaned owner on delete — now a repair belt)" do
    test "deleting the account keeps the person node private and keeps its facts" do
      root = seed_superadmin()
      target = user("penta")
      Person.project(target.id)
      :ok = Person.record_chat_fact(target.id, "based_in", "concept", "Kyiv-secret")

      # a wide person node is impossible even via raw SQL — the DB CHECK belt
      assert_raise Postgrex.Error, ~r/node_person_scope_private/, fn ->
        Swarm.Repo.query!(
          "UPDATE node SET scope='group' WHERE type='user' AND key=$1",
          [target.id]
        )
      end

      # an admin (holds manage_users) deletes the target account — admin via group (ADR-19)
      mgr = user("mgr")
      :ok = Admin.create_group(root, "admins", "Admins", nil)
      :ok = Admin.set_group_role(root, "admins", "admin")
      :ok = Admin.grant_group(root, mgr.id, "admins")
      assert :ok = Admin.delete_user(mgr.id, target.id)

      # person node persists, still private (never discoverable)
      assert Person.node_id(target.id) != nil
      assert person_scope(target.id) == "private"
      # the learned fact persists (D11)
      assert [[_]] =
               Swarm.Repo.query!("SELECT id FROM node WHERE type='concept' AND key='Kyiv-secret'").rows
    end
  end

  defp person_scope(uuid) do
    [[scope]] =
      Swarm.Repo.query!("SELECT scope FROM node WHERE type='user' AND key=$1", [uuid]).rows

    scope
  end

  defp seed_superadmin do
    {:ok, u} =
      Identity.seed_superadmin(%{
        id: Identity.uuid7(),
        login: "root#{System.unique_integer([:positive])}"
      })

    u.id
  end
end
