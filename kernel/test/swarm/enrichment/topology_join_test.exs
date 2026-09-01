defmodule Swarm.Enrichment.TopologyJoinTest do
  use Swarm.GraphCase, async: false

  import ExUnit.CaptureIO

  alias Swarm.Enrichment.NetworkMap
  alias Swarm.Enrichment.TopologyJoin
  alias Swarm.Graph.Store
  alias Swarm.Repo

  @scope Swarm.GraphCase.test_src()

  defp src_node(scope),
    do: %{id: Store.upsert_node("article", "topology-src", scope: scope), scope: scope}

  defp write(facts, opts \\ []) do
    NetworkMap.write(
      src_node(@scope),
      facts,
      Keyword.get(opts, :provenance, "topology-prov-#{System.unique_integer([:positive])}"),
      Keyword.merge(
        [
          origin: Keyword.get(opts, :origin, "iac:test"),
          reliability: 0.85,
          evidence_kind: "observation"
        ],
        opts
      )
    )
  end

  test "derives site joins and host-level gateway joins from host addresses inside evidenced ranges" do
    write([
      %{
        subject: "platform-alpha",
        subject_kind: "cluster",
        relation: "contains",
        object: "app01.example.test",
        object_kind: "host"
      },
      %{
        subject: "platform-alpha",
        subject_kind: "cluster",
        relation: "contains",
        object: "app02.example.test",
        object_kind: "host"
      },
      %{
        subject: "app01.example.test",
        subject_kind: "host",
        relation: "has_address",
        object: "192.0.2.10",
        object_kind: "address"
      },
      %{
        subject: "site-alpha",
        subject_kind: "site",
        relation: "has_address",
        object: "192.0.2.0/24",
        object_kind: "address"
      },
      %{
        subject: "gateway-a",
        subject_kind: "gateway",
        relation: "carries",
        object: "192.0.2.0/24",
        object_kind: "subnet"
      }
    ])

    assert %{joins: 2, dry_run?: false} = TopologyJoin.derive([@scope], apply: true)

    rows =
      Repo.query!("""
      SELECT s.key, e.type, d.key, e.evidence_kind, e.reliability
        FROM edge e
        JOIN node s ON s.id = e.src
        JOIN node d ON d.id = e.dst
       WHERE e.type IN ('contains', 'routes_via')
         AND s.key IN (
           'net:site:site-alpha',
           'net:host:app01.example.test',
           'net:cluster:platform-alpha'
         )
         AND d.key IN ('net:cluster:platform-alpha', 'net:gateway:gateway-a')
       ORDER BY s.key, e.type, d.key
      """).rows

    assert [
             "net:host:app01.example.test",
             "routes_via",
             "net:gateway:gateway-a",
             "derived",
             rel
           ] =
             Enum.find(rows, &(Enum.at(&1, 1) == "routes_via"))

    assert rel >= 0.8

    refute Enum.any?(
             rows,
             &(&1 == [
                 "net:cluster:platform-alpha",
                 "routes_via",
                 "net:gateway:gateway-a",
                 "derived",
                 rel
               ])
           )

    assert Enum.any?(
             rows,
             &(&1 == [
                 "net:site:site-alpha",
                 "contains",
                 "net:cluster:platform-alpha",
                 "derived",
                 rel
               ])
           )

    tree = TopologyJoin.gateway_tree("gateway-a", [@scope])

    assert %{
             cluster_context: [
               %{cluster: "net:cluster:platform-alpha", routed_members: 1, total_members: 2}
             ]
           } =
             Enum.find(
               tree,
               &(&1.src == "net:cluster:platform-alpha" and &1.relation == "contains" and
                   &1.dst == "net:host:app01.example.test")
             )

    assert %{
             cluster_context: [
               %{cluster: "net:cluster:platform-alpha", routed_members: 1, total_members: 2}
             ]
           } =
             Enum.find(
               tree,
               &(&1.src == "net:host:app01.example.test" and &1.relation == "routes_via" and
                   &1.dst == "net:gateway:gateway-a")
             )
  end

  test "fails closed when the host has no address evidence inside a WAN range" do
    write([
      %{
        subject: "platform-alpha",
        subject_kind: "cluster",
        relation: "contains",
        object: "app01.example.test",
        object_kind: "host"
      },
      %{
        subject: "gateway-a",
        subject_kind: "gateway",
        relation: "carries",
        object: "192.0.2.0/24",
        object_kind: "subnet"
      }
    ])

    assert %{joins: 0} = TopologyJoin.derive([@scope], apply: true)

    assert Repo.query!("SELECT count(*) FROM edge WHERE type = 'routes_via'").rows == [[0]]
  end

  test "derives host-level gateway joins through tunnel carries plus terminates_at evidence" do
    write([
      %{
        subject: "platform-alpha",
        subject_kind: "cluster",
        relation: "contains",
        object: "app01.example.test",
        object_kind: "host"
      },
      %{
        subject: "app01.example.test",
        subject_kind: "host",
        relation: "has_address",
        object: "192.0.2.10",
        object_kind: "address"
      },
      %{
        subject: "link-alpha",
        subject_kind: "tunnel",
        relation: "carries",
        object: "192.0.2.0/24",
        object_kind: "subnet"
      },
      %{
        subject: "link-alpha",
        subject_kind: "tunnel",
        relation: "terminates_at",
        object: "gateway-a",
        object_kind: "gateway"
      }
    ])

    assert %{joins: 1} = TopologyJoin.derive([@scope], apply: true)

    assert [
             [
               "net:host:app01.example.test",
               "routes_via",
               "net:gateway:gateway-a",
               ["enrich:topology_join"]
             ]
           ] =
             Repo.query!("""
             SELECT s.key, e.type, d.key,
                    array_agg(DISTINCT ep.origin ORDER BY ep.origin)
               FROM edge e
               JOIN node s ON s.id = e.src
               JOIN node d ON d.id = e.dst
               JOIN edge_provenance ep ON ep.edge_id = e.id
              WHERE e.type = 'routes_via'
              GROUP BY s.key, e.type, d.key
             """).rows
  end

  test "mix task prints host route cluster context as an honest quantifier" do
    write([
      %{
        subject: "platform-alpha",
        subject_kind: "cluster",
        relation: "contains",
        object: "app01.example.test",
        object_kind: "host"
      },
      %{
        subject: "platform-alpha",
        subject_kind: "cluster",
        relation: "contains",
        object: "app02.example.test",
        object_kind: "host"
      },
      %{
        subject: "app01.example.test",
        subject_kind: "host",
        relation: "has_address",
        object: "198.51.100.10",
        object_kind: "address"
      },
      %{
        subject: "gateway-a",
        subject_kind: "gateway",
        relation: "carries",
        object: "198.51.100.0/24",
        object_kind: "subnet"
      }
    ])

    output =
      capture_io(fn ->
        Mix.Task.reenable("swarm.topology_join")

        Mix.Tasks.Swarm.TopologyJoin.run([
          "--scopes",
          @scope,
          "--apply",
          "--gateway",
          "gateway-a"
        ])
      end)

    assert output =~
             "net:host:app01.example.test --routes_via--> net:gateway:gateway-a"

    assert output =~
             "cluster_context=[cluster=net:cluster:platform-alpha routed_hosts=1/2]"
  end

  test "bridges exact IP and FQDN cross-namespace duplicates with alias_of" do
    Store.upsert_node("entity", "192.0.2.10", scope: @scope)
    Store.upsert_node("entity", "app01.example.test", scope: @scope)

    write([
      %{
        subject: "app01.example.test",
        subject_kind: "host",
        relation: "has_address",
        object: "192.0.2.10",
        object_kind: "address"
      }
    ])

    assert %{bridges: 4} = TopologyJoin.derive([@scope], apply: true)

    keys =
      Repo.query!("""
      SELECT s.key, d.key
        FROM edge e
        JOIN node s ON s.id = e.src
        JOIN node d ON d.id = e.dst
       WHERE e.type = 'alias_of'
       ORDER BY s.key, d.key
      """).rows

    assert ["192.0.2.10", "net:address:192.0.2.10"] in keys
    assert ["app01.example.test", "net:host:app01.example.test"] in keys
  end

  test "does not bridge exact duplicates when do-not-merge blocks the pair" do
    Store.upsert_node("entity", "192.0.2.10", scope: @scope)

    write([
      %{
        subject: "app01.example.test",
        subject_kind: "host",
        relation: "has_address",
        object: "192.0.2.10",
        object_kind: "address"
      }
    ])

    Store.block_merge("entity", "192.0.2.10", "net:address:192.0.2.10", "distinct inventory rows")

    assert %{bridges: 0} = TopologyJoin.derive([@scope], apply: true)
    assert Repo.query!("SELECT count(*) FROM edge WHERE type = 'alias_of'").rows == [[0]]
  end

  test "bridges cluster display-name duplicate without treating environments as duplicates" do
    Store.upsert_node("entity", "net:cluster:platform-alpha", scope: @scope)
    Store.upsert_node("entity", "net:cluster:platform-alpha cluster", scope: @scope)
    Store.upsert_node("entity", "net:cluster:platform-alpha-prod", scope: @scope)

    assert %{bridges: 2, variants: 1} = TopologyJoin.derive([@scope], apply: true)

    rows =
      Repo.query!("""
      SELECT s.key, d.key
        FROM edge e
        JOIN node s ON s.id = e.src
        JOIN node d ON d.id = e.dst
       WHERE e.type = 'alias_of'
       ORDER BY s.key, d.key
      """).rows

    assert ["net:cluster:platform-alpha", "net:cluster:platform-alpha cluster"] in rows
    refute Enum.any?(rows, fn row -> "net:cluster:platform-alpha-prod" in row end)
  end

  test "models environment-suffixed clusters as variants without aliasing them" do
    Store.upsert_node("entity", "net:cluster:platform-alpha", scope: @scope)
    Store.upsert_node("entity", "net:cluster:platform-alpha-prod", scope: @scope)
    Store.upsert_node("entity", "net:cluster:platform-alpha-dev", scope: @scope)
    Store.upsert_node("entity", "net:cluster:platform-alpha-prod-old", scope: @scope)

    assert %{variants: 3} = TopologyJoin.derive([@scope], apply: true)

    assert Repo.query!("SELECT count(*) FROM node_do_not_merge").rows == [[3]]

    rows =
      Repo.query!("""
      SELECT d.key
        FROM edge e
        JOIN node s ON s.id = e.src
        JOIN node d ON d.id = e.dst
       WHERE s.key = 'net:cluster:platform-alpha' AND e.type = 'contains'
       ORDER BY d.key
      """).rows

    assert rows == [
             ["net:cluster:platform-alpha-dev"],
             ["net:cluster:platform-alpha-prod"],
             ["net:cluster:platform-alpha-prod-old"]
           ]

    assert Repo.query!("SELECT count(*) FROM edge WHERE type = 'alias_of'").rows == [[0]]
  end
end
