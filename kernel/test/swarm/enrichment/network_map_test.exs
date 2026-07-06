defmodule Swarm.Enrichment.NetworkMapTest do
  @moduledoc """
  Network-map skeleton extraction (ADR-17 world-map): the cheap gate, the conservative/grounded
  macro parse (governed vocabulary, address refusal, self-loop guard), and the write that emits
  namespaced `entity` nodes + `is_a` type edges + governed relation edges (symmetric doubling,
  scope clamp, hypothesis band).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.NetworkMap
  alias Swarm.Graph.Network
  alias Swarm.Graph.Store
  alias Swarm.Repo

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
      node = src_node("group")

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

      %{entities: entities, relations: relations} = Network.map(["group"])
      keys = Enum.map(entities, & &1.key) |> Enum.sort()
      assert "net:site:paris" in keys
      assert "net:gateway:gw-core" in keys

      assert [%{src: "site/paris", relation: "routes_via", dst: "gateway/gw-core"}] = relations
    end

    test "symmetric relations (connects_site) emit BOTH directions" do
      node = src_node("group")

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
      %{relations: relations} = Network.map(["group"])
      pairs = Enum.map(relations, &{&1.src, &1.dst}) |> Enum.sort()
      assert {"site/lyon", "site/paris"} in pairs
      assert {"site/paris", "site/lyon"} in pairs
    end

    test "no-leak: a PUBLIC source clamps network nodes/edges to group (never public)" do
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

      # visible at group
      assert %{entities: [_ | _]} = Network.map(["group"])
      # NOT visible at a public-only read
      assert %{entities: [], relations: []} = Network.map(["public"])
    end

    test "network edges carry the hypothesis band (low reliability)" do
      node = src_node("group")

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
