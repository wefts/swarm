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
  @net_scope2 Swarm.GraphCase.test_src2()
  @dim Swarm.Config.embedding_dim()

  defp vecn(i), do: for(j <- 0..(@dim - 1), do: if(j == i, do: 1.0, else: 0.0))

  defp src_node(scope),
    do: %{id: Store.upsert_node("article", "net-read-src", scope: scope), scope: scope}

  defp src_node(scope, key),
    do: %{id: Store.upsert_node("article", key, scope: scope), scope: scope}

  test "empty scopes yield an empty map (no query)" do
    assert Network.map([]) == %{entities: [], relations: []}
    assert Network.entities([]) == []
    assert Network.relations([]) == []
  end

  test "declares relation cardinality for renderers" do
    assert Network.cardinality("hosted_on") == :single
    assert Network.cardinality("has_private_address") == :many
    assert Network.cardinality("contained_by") == :many
    assert Network.cardinality("routes_for") == :many
    assert Network.cardinality("unknown_relation") == :many
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

  test "neighborhood/3 filters public/private address relations and labels generic addresses" do
    node = src_node(@net_scope)

    NetworkMap.write(
      node,
      [
        %{
          subject: "example-host",
          subject_kind: "host",
          relation: "has_address",
          object: "10.20.30.1",
          object_kind: "address"
        },
        %{
          subject: "example-host",
          subject_kind: "host",
          relation: "has_address",
          object: "8.8.8.8",
          object_kind: "address"
        }
      ],
      "prov-address-class"
    )

    assert [
             %{relation: "has_private_address", object: "address/10.20.30.1"}
           ] =
             Network.neighborhood("net:host:example-host", [@net_scope],
               min_corroboration: 1,
               relations: ["has_private_address"]
             )

    assert [
             %{relation: "has_public_address", object: "address/8.8.8.8"}
           ] =
             Network.neighborhood("net:host:example-host", [@net_scope],
               min_corroboration: 1,
               relations: ["has_public_address"]
             )

    facts = Network.neighborhood("net:host:example-host", [@net_scope], min_corroboration: 1)

    assert Enum.any?(
             facts,
             &match?(
               %{relation: "has_address", object: "address/10.20.30.1", address_class: "private"},
               &1
             )
           )

    assert Enum.any?(
             facts,
             &match?(
               %{relation: "has_address", object: "address/8.8.8.8", address_class: "public"},
               &1
             )
           )

    refute Enum.any?(facts, &(&1.relation in ["has_private_address", "has_public_address"]))
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

  test "candidates/3 extracts exact network literals" do
    node = src_node(@net_scope)

    NetworkMap.write(
      node,
      [
        %{
          subject: "edge.example.test",
          subject_kind: "gateway",
          relation: "carries",
          object: "192.0.2.0/25",
          object_kind: "subnet"
        },
        %{
          subject: "box.example.test",
          subject_kind: "host",
          relation: "routes_via",
          object: "192.0.2.1",
          object_kind: "gateway"
        },
        %{
          subject: "box.example.test",
          subject_kind: "host",
          relation: "has_address",
          object: "192.0.2.30",
          object_kind: "address"
        }
      ],
      "prov-literal"
    )

    assert "net:gateway:192.0.2.1" in Network.candidates("which gateway is 192.0.2.1?", [
             @net_scope
           ])

    assert "net:address:192.0.2.30" in Network.candidates(
             "which subnet contains 192.0.2.30?",
             [@net_scope]
           )

    assert "net:gateway:192.0.2.1" in Network.candidates("which hosts route via 192.0.2.1?", [
             @net_scope
           ])
  end

  test "neighborhood/3 derives address containment with inet/cidr operators" do
    node = src_node(@net_scope)

    NetworkMap.write(
      node,
      [
        %{
          subject: "example-tunnel",
          subject_kind: "tunnel",
          relation: "carries",
          object: "192.0.2.0/25",
          object_kind: "subnet"
        },
        %{
          subject: "inside.example.test",
          subject_kind: "host",
          relation: "has_address",
          object: "192.0.2.30",
          object_kind: "address"
        },
        %{
          subject: "outside.example.test",
          subject_kind: "host",
          relation: "has_address",
          object: "192.0.2.200",
          object_kind: "address"
        }
      ],
      "prov-containment"
    )

    assert [
             %{relation: "contained_by", object: "subnet/192.0.2.0/25"}
           ] =
             Network.neighborhood("net:address:192.0.2.30", [@net_scope], min_corroboration: 1)

    assert [] =
             Network.neighborhood("net:address:192.0.2.200", [@net_scope], min_corroboration: 1)
  end

  test "neighborhood/3 derives gateway reverse route facts" do
    node = src_node(@net_scope)

    NetworkMap.write(
      node,
      [
        %{
          subject: "app.example.test",
          subject_kind: "host",
          relation: "routes_via",
          object: "192.0.2.1",
          object_kind: "gateway"
        }
      ],
      "prov-reverse-route"
    )

    assert [
             %{relation: "routes_for", object: "host/app.example.test"}
           ] =
             Network.neighborhood("net:gateway:192.0.2.1", [@net_scope], min_corroboration: 1)
  end

  test "neighborhood/3 synthesizes routes_via only when host address and gateway range are both visible" do
    source_a = src_node(@net_scope, "route-source-a")
    source_b = src_node(@net_scope2, "route-source-b")

    NetworkMap.write(
      source_a,
      [
        %{
          subject: "app01.example.test",
          subject_kind: "host",
          relation: "has_address",
          object: "10.20.30.10",
          object_kind: "address"
        }
      ],
      "prov-route-host",
      origin: "wiki:hosts"
    )

    NetworkMap.write(
      source_b,
      [
        %{
          subject: "gateway-a",
          subject_kind: "gateway",
          relation: "carries",
          object: "10.20.30.0/24",
          object_kind: "subnet"
        }
      ],
      "prov-route-gateway",
      origin: "wiki:network"
    )

    host_key = "net:host:app01.example.test"

    refute Enum.any?(
             Network.neighborhood(host_key, [@net_scope], min_corroboration: 1),
             &match?(%{relation: "routes_via"}, &1)
           )

    refute Enum.any?(
             Network.neighborhood(host_key, [@net_scope2], min_corroboration: 1),
             &match?(%{relation: "routes_via"}, &1)
           )

    assert [
             %{relation: "routes_via", object: "gateway/gateway-a", object_kind: "gateway"}
           ] =
             Network.neighborhood(host_key, [@net_scope, @net_scope2], min_corroboration: 1)
             |> Enum.filter(&(&1.relation == "routes_via"))
  end

  test "neighborhood/3 synthesizes reverse routes_for only when gateway range and host address are both visible" do
    source_a = src_node(@net_scope, "reverse-route-source-a")
    source_b = src_node(@net_scope2, "reverse-route-source-b")

    NetworkMap.write(
      source_a,
      [
        %{
          subject: "app01.example.test",
          subject_kind: "host",
          relation: "has_address",
          object: "10.20.30.10",
          object_kind: "address"
        }
      ],
      "prov-reverse-route-host",
      origin: "wiki:hosts"
    )

    NetworkMap.write(
      source_b,
      [
        %{
          subject: "gateway-a",
          subject_kind: "gateway",
          relation: "carries",
          object: "10.20.30.0/24",
          object_kind: "subnet"
        }
      ],
      "prov-reverse-route-gateway",
      origin: "wiki:network"
    )

    gateway_key = "net:gateway:gateway-a"

    refute Enum.any?(
             Network.neighborhood(gateway_key, [@net_scope], min_corroboration: 1),
             &match?(%{relation: "routes_for"}, &1)
           )

    refute Enum.any?(
             Network.neighborhood(gateway_key, [@net_scope2], min_corroboration: 1),
             &match?(%{relation: "routes_for"}, &1)
           )

    assert [
             %{relation: "routes_for", object: "host/app01.example.test", object_kind: "host"}
           ] =
             Network.neighborhood(gateway_key, [@net_scope, @net_scope2], min_corroboration: 1)
             |> Enum.filter(&(&1.relation == "routes_for"))
  end

  test "neighborhood/3 synthesizes routes through tunnel-carried ranges terminated at a gateway" do
    source_a = src_node(@net_scope, "tunnel-route-source-a")
    source_b = src_node(@net_scope2, "tunnel-route-source-b")

    NetworkMap.write(
      source_a,
      [
        %{
          subject: "app01.example.test",
          subject_kind: "host",
          relation: "has_address",
          object: "10.20.30.10",
          object_kind: "address"
        }
      ],
      "prov-tunnel-route-host",
      origin: "wiki:hosts"
    )

    NetworkMap.write(
      source_b,
      [
        %{
          subject: "tunnel-a",
          subject_kind: "tunnel",
          relation: "carries",
          object: "10.20.30.0/24",
          object_kind: "subnet"
        },
        %{
          subject: "tunnel-a",
          subject_kind: "tunnel",
          relation: "terminates_at",
          object: "gateway-a",
          object_kind: "gateway"
        }
      ],
      "prov-tunnel-route-gateway",
      origin: "wiki:network"
    )

    host_key = "net:host:app01.example.test"
    gateway_key = "net:gateway:gateway-a"

    assert [] =
             Network.neighborhood(host_key, [@net_scope], min_corroboration: 1)
             |> Enum.filter(&(&1.relation == "routes_via"))

    assert [] =
             Network.neighborhood(gateway_key, [@net_scope2], min_corroboration: 1)
             |> Enum.filter(&(&1.relation == "routes_for"))

    assert [
             %{relation: "routes_via", object: "gateway/gateway-a", object_kind: "gateway"}
           ] =
             Network.neighborhood(host_key, [@net_scope, @net_scope2], min_corroboration: 1)
             |> Enum.filter(&(&1.relation == "routes_via"))

    assert [
             %{relation: "routes_for", object: "host/app01.example.test", object_kind: "host"}
           ] =
             Network.neighborhood(gateway_key, [@net_scope, @net_scope2], min_corroboration: 1)
             |> Enum.filter(&(&1.relation == "routes_for"))
  end

  test "neighborhood/3 relation filters exclude synthesized route facts" do
    source_a = src_node(@net_scope, "filtered-route-source-a")
    source_b = src_node(@net_scope2, "filtered-route-source-b")

    NetworkMap.write(
      source_a,
      [
        %{
          subject: "app01.example.test",
          subject_kind: "host",
          relation: "has_address",
          object: "10.20.30.10",
          object_kind: "address"
        }
      ],
      "prov-filtered-route-host",
      origin: "wiki:hosts"
    )

    NetworkMap.write(
      source_b,
      [
        %{
          subject: "gateway-a",
          subject_kind: "gateway",
          relation: "carries",
          object: "10.20.30.0/24",
          object_kind: "subnet"
        }
      ],
      "prov-filtered-route-gateway",
      origin: "wiki:network"
    )

    scopes = [@net_scope, @net_scope2]

    refute Enum.any?(
             Network.neighborhood("net:host:app01.example.test", scopes,
               min_corroboration: 1,
               relations: ["has_address"]
             ),
             &match?(%{relation: "routes_via"}, &1)
           )

    refute Enum.any?(
             Network.neighborhood("net:gateway:gateway-a", scopes,
               min_corroboration: 1,
               relations: ["carries"]
             ),
             &match?(%{relation: "routes_for"}, &1)
           )
  end

  test "neighborhood/3 derives gateway reverse tunnel termination facts" do
    node = src_node(@net_scope)

    NetworkMap.write(
      node,
      [
        %{
          subject: "example-tunnel",
          subject_kind: "tunnel",
          relation: "terminates_at",
          object: "192.0.2.1",
          object_kind: "gateway"
        }
      ],
      "prov-reverse-termination"
    )

    assert [
             %{relation: "terminates_for", object: "tunnel/example-tunnel"}
           ] =
             Network.neighborhood("net:gateway:192.0.2.1", [@net_scope],
               min_corroboration: 1,
               relations: ["terminates_for"]
             )
  end

  test "candidates/3 finds typed service entities with direct address facts" do
    subject = Store.upsert_node("entity", "net:service:nebula-ci-runners", scope: @net_scope)
    address = Store.upsert_node("entity", "net:address:192.0.2.10", scope: @net_scope)

    {:ok, _} =
      Store.add_edge(subject, address, "has_outbound_ip_address", "example.test:net",
        scope: @net_scope,
        origin: "example.test:net",
        evidence_kind: "claim",
        source_node_id: subject
      )

    assert ["net:service:nebula-ci-runners"] =
             Network.candidates("Яке публічне IP у nebula runners?", [@net_scope])
  end

  test "candidates/3 uses vector fallback for held-out paraphrases and keeps scope fences" do
    site = Store.upsert_node("entity", "net:site:example-alpha", scope: @net_scope)
    address = Store.upsert_node("entity", "net:address:192.0.2.44", scope: @net_scope)

    Swarm.Repo.query!("UPDATE node SET vec = $2 WHERE id = $1", [site, Pgvector.new(vecn(5))])

    {:ok, _} =
      Store.add_edge(site, address, "has_address", "example.test:net",
        scope: @net_scope,
        origin: "example.test:net",
        evidence_kind: "claim",
        source_node_id: site
      )

    assert ["net:site:example-alpha"] =
             Network.candidates("How is the site addressed internally?", [@net_scope],
               query_vec: vecn(5)
             )

    assert Network.candidates("How is the site addressed internally?", ["public"],
             query_vec: vecn(5)
           ) == []
  end

  test "candidates/3 uses vector-nearest scoped nodes to seed unembedded net keys" do
    site = Store.upsert_node("entity", "net:site:example-beta", scope: @net_scope)
    address = Store.upsert_node("entity", "net:address:192.0.2.45", scope: @net_scope)
    article = Store.upsert_node("article", "Example Beta", scope: @net_scope)

    Swarm.Repo.query!("UPDATE node SET vec = $2 WHERE id = $1", [article, Pgvector.new(vecn(6))])

    {:ok, _} =
      Store.add_edge(site, address, "has_address", "example.test:net",
        scope: @net_scope,
        origin: "example.test:net",
        evidence_kind: "claim",
        source_node_id: site
      )

    assert "net:site:example-beta" in Network.candidates(
             "Яке публічне IP у тестової бети?",
             [@net_scope],
             query_vec: vecn(6)
           )

    assert Network.candidates("Яке публічне IP у тестової бети?", ["public"], query_vec: vecn(6)) ==
             []
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
    subject =
      Store.upsert_node("entity", "net:service:ci-runners.example.test", scope: @net_scope)

    address = Store.upsert_node("entity", "net:address:203.0.113.118", scope: @net_scope)
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

    facts =
      Network.neighborhood("net:service:ci-runners.example.test", [@net_scope],
        min_corroboration: 1
      )

    assert Enum.any?(
             facts,
             &match?(%{relation: "has_outbound_ip_address", object: "address/203.0.113.118"}, &1)
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
