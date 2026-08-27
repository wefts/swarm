defmodule Swarm.Enrichment.NetworkMapTest do
  @moduledoc """
  Network-map skeleton extraction (ADR-17 world-map): the cheap gate, the conservative/grounded
  macro parse (governed vocabulary, address refusal, self-loop guard), and the write that emits
  namespaced `entity` nodes + `is_a` type edges + governed relation edges (symmetric doubling,
  per-source scope inheritance, hypothesis band).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.NetworkMap
  alias Swarm.Graph.Network
  alias Swarm.Graph.Store
  alias Swarm.Repo

  @net_scope Swarm.GraphCase.test_src()

  defp gen(json), do: fn _m, _p, _o -> {:ok, json} end

  defp src_node(scope),
    do: %{id: Store.upsert_node("article", "net-src-doc", scope: scope), scope: scope}

  describe "network?/1 (cheap gate)" do
    test "true on topology vocabulary / address / FQDN signals" do
      assert NetworkMap.network?("The gateway routes traffic to the firewall.")
      assert NetworkMap.network?("An IPsec tunnel connects the two sites.")
      assert NetworkMap.network?("host lives at 10.20.30.40")
      assert NetworkMap.network?("the subnet is 10.20.30.0/24")
      assert NetworkMap.network?("reach it at gw01.intranet for details")
      assert NetworkMap.network?("the kubespray cluster exposes an ingress")
    end

    test "false on plain non-network prose (no 2nd LLM pass paid)" do
      refute NetworkMap.network?("How to reset your email signature in the client.")
      refute NetworkMap.network?("")
      refute NetworkMap.network?(nil)
    end
  end

  describe "extract/2" do
    test "a non-network body never calls the model (gated)" do
      boom = fn _m, _p, _o -> raise "must not run the LLM on non-network text" end
      assert NetworkMap.extract("how to change your password in the portal", gen_fun: boom) == []
    end

    test "extracts a grounded macro fact with governed relation + kinds" do
      body = "The site paris routes_via the gateway gw-core to reach other agencies."

      json =
        ~s({"facts":[{"subject":"paris","subject_kind":"site","relation":"routes_via","object":"gw-core","object_kind":"gateway"}]})

      assert [fact] = NetworkMap.extract(body, gen_fun: gen(json))
      assert fact.subject == "paris"
      assert fact.subject_kind == "site"
      assert fact.relation == "routes_via"
      assert fact.object == "gw-core"
      assert fact.object_kind == "gateway"
    end

    test "drops a fact with an out-of-vocabulary relation" do
      body = "gw-core somehow relates to fw-lille"

      json =
        ~s({"facts":[{"subject":"gw-core","subject_kind":"gateway","relation":"behind_firewall","object":"fw-lille","object_kind":"firewall"}]})

      assert NetworkMap.extract(body, gen_fun: gen(json)) == []
    end

    test "drops a fact with an out-of-vocabulary kind" do
      body = "the widget gw-core protected_by fw-lille firewall"

      json =
        ~s({"facts":[{"subject":"gw-core","subject_kind":"widget","relation":"protected_by","object":"fw-lille","object_kind":"firewall"}]})

      assert NetworkMap.extract(body, gen_fun: gen(json)) == []
    end

    test "refuses bare IP / CIDR endpoint names (macro-only; addresses wait for Phase-2)" do
      body = "host web01 in_subnet 10.20.30.0/24 which contains 10.20.30.5"

      json =
        ~s({"facts":[{"subject":"web01","subject_kind":"host","relation":"contains","object":"10.20.30.0/24","object_kind":"subnet"}]})

      assert NetworkMap.extract(body, gen_fun: gen(json)) == []
    end

    test "drops an ungrounded (invented) endpoint name" do
      body = "the gateway gw-core protects the paris site"
      # 'fw-ghost' is not in the body — hallucinated endpoint
      json =
        ~s({"facts":[{"subject":"paris","subject_kind":"site","relation":"protected_by","object":"fw-ghost","object_kind":"firewall"}]})

      assert NetworkMap.extract(body, gen_fun: gen(json)) == []
    end

    test "drops a mis-typed relation↔kind signature (gateway hosted_on subnet)" do
      body = "the gateway opnsense is hosted_on the lansitesur subnet"

      # gateway hosted_on subnet is a real observed error — hosted_on object must be host/cluster
      json =
        ~s({"facts":[{"subject":"opnsense","subject_kind":"gateway","relation":"hosted_on","object":"lansitesur","object_kind":"subnet"}]})

      assert NetworkMap.extract(body, gen_fun: gen(json)) == []
    end

    test "drops connects_site between hosts (must be site↔site)" do
      body = "host hercules connects_site to host swnet"

      json =
        ~s({"facts":[{"subject":"hercules","subject_kind":"host","relation":"connects_site","object":"swnet","object_kind":"host"}]})

      assert NetworkMap.extract(body, gen_fun: gen(json)) == []
    end

    test "keeps a well-typed fact (service hosted_on host)" do
      body = "In the cluster, the icinga service is hosted on the lyderic node."

      json =
        ~s({"facts":[{"subject":"icinga","subject_kind":"service","relation":"hosted_on","object":"lyderic","object_kind":"host"}]})

      assert [%{subject: "icinga", object: "lyderic"}] =
               NetworkMap.extract(body, gen_fun: gen(json))
    end

    test "alias_of requires matching endpoint kinds" do
      body = "gw01 is an alias_of gw01.corp and both are hosts"

      good =
        ~s({"facts":[{"subject":"gw01","subject_kind":"host","relation":"alias_of","object":"gw01.corp","object_kind":"host"}]})

      bad =
        ~s({"facts":[{"subject":"gw01","subject_kind":"host","relation":"alias_of","object":"gw01.corp","object_kind":"subnet"}]})

      assert [%{relation: "alias_of"}] = NetworkMap.extract(body, gen_fun: gen(good))
      assert NetworkMap.extract(body, gen_fun: gen(bad)) == []
    end

    test "drops a self-loop (same kind + same name)" do
      body = "core relates to core"

      json =
        ~s({"facts":[{"subject":"core","subject_kind":"host","relation":"routes_via","object":"core","object_kind":"host"}]})

      assert NetworkMap.extract(body, gen_fun: gen(json)) == []
    end

    test "model error yields []" do
      body = "the gateway gw-core routes traffic"
      assert NetworkMap.extract(body, gen_fun: fn _m, _p, _o -> {:error, :boom} end) == []
    end
  end

  describe "write/3" do
    test "emits namespaced entity nodes, is_a type markers, and the relation edge" do
      node = src_node(@net_scope)

      facts = [
        %{
          subject: "paris",
          subject_kind: "site",
          relation: "routes_via",
          object: "gw-core",
          object_kind: "gateway"
        }
      ]

      ids = NetworkMap.write(node, facts, "prov-1")
      # 2 is_a edges + 1 relation edge
      assert length(ids) == 3

      %{entities: entities, relations: relations} = Network.map([@net_scope])
      keys = Enum.map(entities, & &1.key) |> Enum.sort()
      assert "net:site:paris" in keys
      assert "net:gateway:gw-core" in keys

      assert Repo.query!("SELECT scope FROM node WHERE key = 'net:kind:site'").rows == [
               ["public"]
             ]

      assert [%{src: "site/paris", relation: "routes_via", dst: "gateway/gw-core"}] = relations
    end

    test "symmetric relations (connects_site) emit BOTH directions" do
      node = src_node(@net_scope)

      facts = [
        %{
          subject: "paris",
          subject_kind: "site",
          relation: "connects_site",
          object: "lyon",
          object_kind: "site"
        }
      ]

      _ids = NetworkMap.write(node, facts, "prov-sym")
      %{relations: relations} = Network.map([@net_scope])
      pairs = Enum.map(relations, &{&1.src, &1.dst}) |> Enum.sort()
      assert {"site/lyon", "site/paris"} in pairs
      assert {"site/paris", "site/lyon"} in pairs
    end

    test "network data inherits the source scope, including public sources" do
      node = src_node("public")

      facts = [
        %{
          subject: "paris",
          subject_kind: "site",
          relation: "routes_via",
          object: "gw-core",
          object_kind: "gateway"
        }
      ]

      NetworkMap.write(node, facts, "prov-pub")

      assert Repo.query!("SELECT scope FROM node WHERE key = 'net:site:paris'").rows == [
               ["public"]
             ]

      assert Repo.query!("SELECT scope FROM node WHERE key = 'net:kind:site'").rows == [
               ["public"]
             ]

      assert Repo.query!("SELECT DISTINCT visibility_scope FROM edge WHERE type = 'routes_via'").rows ==
               [["public"]]

      assert %{entities: [_ | _], relations: [_ | _]} = Network.map(["public"])
    end

    test "Phase-2 opts: distinct origin corroborates a matching wiki edge (ADR-13 seen_count↑)" do
      node = src_node(@net_scope)

      facts = [
        %{
          subject: "orbit",
          subject_kind: "tunnel",
          relation: "terminates_at",
          object: "gw-peer",
          object_kind: "gateway"
        }
      ]

      # Phase-1 (wiki prose) writes the hypothesis
      NetworkMap.write(node, facts, "wiki-prov", origin: "enrich:origin:node:#{node.id}")
      # Phase-2 (repo) writes the SAME fact with a distinct origin + high reliability
      NetworkMap.write(node, facts, "iac-prov",
        origin: "iac:nebula-forge-cloud-cluster",
        reliability: 0.85,
        evidence_kind: "observation"
      )

      %{rows: [[seen]]} =
        Repo.query!("SELECT seen_count FROM edge WHERE type = 'terminates_at' LIMIT 1")

      # two distinct origins on one edge → corroborated
      assert seen == 2
    end

    test "Phase-2 opts set reliability + evidence_kind on the edge" do
      node = src_node(@net_scope)

      facts = [
        %{
          subject: "orbit",
          subject_kind: "tunnel",
          relation: "carries",
          object: "10.0.0.0/8",
          object_kind: "subnet"
        }
      ]

      NetworkMap.write(node, facts, "iac-prov",
        origin: "iac:repo",
        reliability: 0.85,
        evidence_kind: "observation"
      )

      %{rows: [[kind, rel]]} =
        Repo.query!("SELECT evidence_kind, reliability FROM edge WHERE type = 'carries' LIMIT 1")

      assert kind == "observation"
      assert rel >= 0.8
    end

    test "has_address (host → address, IP object) is admitted via the write path (table facts)" do
      node = src_node(@net_scope)
      # bare-IP object: refused by the LLM extract path (Phase-1), but the table parser feeds it
      # directly to write, where admissible?/1 (vocab+signature) allows host → has_address → address
      facts = [
        %{
          subject: "web01.corp",
          subject_kind: "host",
          relation: "has_address",
          object: "10.0.0.5",
          object_kind: "address"
        }
      ]

      assert [_ | _] =
               NetworkMap.write(node, facts, "wiki:tables",
                 origin: "wiki:tables",
                 reliability: 0.55,
                 evidence_kind: "observation"
               )

      %{relations: rels} = Network.map([@net_scope])
      assert Enum.any?(rels, &(&1.relation == "has_address" and &1.src == "host/web01.corp"))
    end

    test "write signature-filters a directly-fed mis-typed fact" do
      node = src_node(@net_scope)

      facts = [
        # gateway hosted_on subnet — mis-typed, must be dropped even on the direct-write path
        %{
          subject: "gw",
          subject_kind: "gateway",
          relation: "hosted_on",
          object: "net",
          object_kind: "subnet"
        }
      ]

      assert NetworkMap.write(node, facts, "iac-prov", origin: "iac:repo") == []
    end

    test "network edges carry the hypothesis band (low reliability)" do
      node = src_node(@net_scope)

      facts = [
        %{
          subject: "svc-a",
          subject_kind: "service",
          relation: "hosted_on",
          object: "cl-main",
          object_kind: "cluster"
        }
      ]

      NetworkMap.write(node, facts, "prov-rel")

      %{rows: [[kind, rel]]} =
        Repo.query!(
          "SELECT evidence_kind, reliability FROM edge WHERE type = 'hosted_on' LIMIT 1"
        )

      assert kind == "hypothesis"
      assert rel <= 0.4
    end
  end
end
