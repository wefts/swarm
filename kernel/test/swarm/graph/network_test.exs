defmodule Swarm.Graph.NetworkTest do
  @moduledoc """
  Network-map READ view (ADR-17 world-map): scope-enforced reconstruction of the topology
  skeleton, is_a edges folded out of relations, and empty-input guards.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.NetworkMap
  alias Swarm.Graph.Network
  alias Swarm.Graph.Store

  defp src_node(scope),
    do: %{id: Store.upsert_node("article", "net-read-src", scope: scope), scope: scope}

  test "empty scopes yield an empty map (no query)" do
    assert Network.map([]) == %{entities: [], relations: []}
    assert Network.entities([]) == []
    assert Network.relations([]) == []
  end

  test "relations exclude is_a typing edges; entities carry decoded kind + name" do
    node = src_node("group")

    facts = [
      %{
        subject: "web01",
        subject_kind: "host",
        relation: "protected_by",
        object: "fw-edge",
        object_kind: "firewall"
      }
    ]

    NetworkMap.write(node, facts, "prov-read")

    %{entities: entities, relations: relations} = Network.map(["group"])

    host = Enum.find(entities, &(&1.key == "net:host:web01"))
    assert host.kind == "host"
    assert host.name == "web01"

    # only the protected_by relation surfaces — the two is_a edges are folded out
    assert [%{relation: "protected_by", src: "host/web01", dst: "firewall/fw-edge"}] = relations
    refute Enum.any?(relations, &(&1.relation == "is_a"))
  end
end
