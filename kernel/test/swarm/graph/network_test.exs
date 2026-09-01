defmodule Swarm.Graph.NetworkTest do
  @moduledoc """
  Network-map READ view (ADR-17 world-map): scope-enforced reconstruction of the topology
  skeleton, is_a edges folded out of relations, and empty-input guards.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.NetworkMap
  alias Swarm.Graph.Network
  alias Swarm.Graph.Store

  @net_scope Swarm.GraphCase.test_src()

  defp src_node(scope),
    do: %{id: Store.upsert_node("article", "net-read-src", scope: scope), scope: scope}

  test "empty scopes yield an empty map (no query)" do
    assert Network.map([]) == %{entities: [], relations: []}
    assert Network.entities([]) == []
    assert Network.relations([]) == []
  end

  test "relations exclude is_a typing edges; entities carry decoded kind + name" do
    node = src_node(@net_scope)

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

    %{entities: entities, relations: relations} = Network.map([@net_scope])

    host = Enum.find(entities, &(&1.key == "net:host:web01"))
    assert host.kind == "host"
    assert host.name == "web01"

    # only the protected_by relation surfaces — the two is_a edges are folded out
    assert [%{relation: "protected_by", src: "host/web01", dst: "firewall/fw-edge"}] = relations
    refute Enum.any?(relations, &(&1.relation == "is_a"))
  end

  test "candidates/3 finds net entities matching a query term (with a relation edge)" do
    node = src_node(@net_scope)

    facts = [
      %{
        subject: "orbit",
        subject_kind: "tunnel",
        relation: "carries",
        object: "10.1.0.0/16",
        object_kind: "subnet"
      }
    ]

    NetworkMap.write(node, facts, "prov-c")

    assert "net:tunnel:orbit" in Network.candidates("what does the orbit tunnel carry", [
             @net_scope
           ])

    assert Network.candidates("something unrelated entirely", [@net_scope]) == []
    assert Network.candidates("orbit", []) == []
  end

  test "candidates/3 finds non-net entities with direct address facts" do
    subject = Store.upsert_node("entity", "Nebula CI runners", scope: @net_scope)
    address = Store.upsert_node("entity", "192.0.2.10", scope: @net_scope)

    {:ok, _} =
      Store.add_edge(subject, address, "has_outbound_ip_address", "example.test:net",
        scope: @net_scope,
        origin: "example.test:net",
        evidence_kind: "claim",
        source_node_id: subject
      )

    assert ["Nebula CI runners"] =
             Network.candidates("Яке публічне IP у nebula runners?", [@net_scope])
  end

  test "neighborhood/3 S2: a STALE fact (old last_seen vs frontier) is filtered from serve" do
    node = src_node(@net_scope)

    # a fresh fact + a stale one; a much-newer frontier edge makes the stale one age past its cutoff
    NetworkMap.write(
      node,
      [
        %{
          subject: "conduit",
          subject_kind: "tunnel",
          relation: "carries",
          object: "10.9.0.0/16",
          object_kind: "subnet"
        }
      ],
      "prov-fresh"
    )

    # backdate the conduit carries edge far past the structural half-life relative to the frontier
    Swarm.Repo.query!(
      "UPDATE edge SET last_seen = now() - interval '400 days' WHERE type='carries' AND src=(SELECT id FROM node WHERE key='net:tunnel:conduit')"
    )

    # a newer edge sets the frontier to ~now
    NetworkMap.write(
      node,
      [
        %{
          subject: "conduit",
          subject_kind: "tunnel",
          relation: "terminates_at",
          object: "gw-x",
          object_kind: "gateway"
        }
      ],
      "prov-now"
    )

    facts = Network.neighborhood("net:tunnel:conduit", [@net_scope], min_corroboration: 1)
    relations = Enum.map(facts, & &1.relation)
    assert "terminates_at" in relations
    refute "carries" in relations
    # freshness off → the stale fact reappears
    assert "carries" in Enum.map(
             Network.neighborhood("net:tunnel:conduit", [@net_scope],
               min_corroboration: 1,
               freshness: false
             ),
             & &1.relation
           )
  end

  test "neighborhood/3 S2: fresh structural edges do not stale configuration facts" do
    subject = Store.upsert_node("entity", "Galaxy CI/CD runners", scope: @net_scope)
    address = Store.upsert_node("entity", "203.0.113.118", scope: @net_scope)
    dependency = Store.upsert_node("entity", "Build egress profile", scope: @net_scope)
    site = Store.upsert_node("entity", "net:site:dev", scope: @net_scope)

    {:ok, _} =
      Store.add_edge(subject, address, "has_outbound_ip_address", "example.test:ip",
        scope: @net_scope,
        origin: "example.test:ip",
        evidence_kind: "claim",
        source_node_id: subject
      )

    {:ok, _} =
      Store.add_edge(subject, dependency, "uses", "example.test:config",
        scope: @net_scope,
        origin: "example.test:config",
        evidence_kind: "claim",
        source_node_id: subject
      )

    Swarm.Repo.query!(
      "UPDATE edge SET last_seen = now() - interval '40 days' WHERE src = $1 AND type = 'has_outbound_ip_address'",
      [subject]
    )

    Swarm.Repo.query!(
      "UPDATE edge SET last_seen = now() - interval '20 days' WHERE src = $1 AND type = 'uses'",
      [subject]
    )

    {:ok, _} =
      Store.add_edge(subject, site, "contains", "example.test:topology",
        scope: @net_scope,
        origin: "example.test:topology",
        evidence_kind: "claim",
        source_node_id: subject
      )

    facts = Network.neighborhood("Galaxy CI/CD runners", [@net_scope], min_corroboration: 1)

    assert Enum.any?(
             facts,
             &match?(%{relation: "has_outbound_ip_address", object: "203.0.113.118"}, &1)
           )

    assert Enum.any?(facts, &match?(%{relation: "contains", object: "site/dev"}, &1))
  end

  test "neighborhood/3 with min_corroboration filters to multi-origin facts" do
    node = src_node(@net_scope)

    facts = [
      %{
        subject: "orbit",
        subject_kind: "tunnel",
        relation: "carries",
        object: "10.2.0.0/16",
        object_kind: "subnet"
      }
    ]

    # single origin → seen_count 1
    NetworkMap.write(node, facts, "prov-1", origin: "iac:repo")

    assert Network.neighborhood("net:tunnel:orbit", [@net_scope], min_corroboration: 2) == []

    assert [%{relation: "carries"}] =
             Network.neighborhood("net:tunnel:orbit", [@net_scope], min_corroboration: 1)

    # second distinct origin on the SAME edge → seen_count 2 → now passes the ≥2 floor
    NetworkMap.write(node, facts, "prov-2", origin: "wiki:corrob")

    assert [%{relation: "carries", corroboration: 2}] =
             Network.neighborhood("net:tunnel:orbit", [@net_scope], min_corroboration: 2)
  end
end
