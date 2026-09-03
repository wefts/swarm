defmodule Swarm.Enrichment.PageTreeProjectionTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.PageTreeProjection
  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp gen(json), do: fn _m, _p, _o -> {:ok, json} end

  defp source_node(scope \\ test_src()) do
    %{id: Store.upsert_node("article", "child-page", scope: scope), scope: scope}
  end

  describe "classify/4" do
    test "filing bucket parents fail closed without a model call" do
      boom = fn _m, _p, _o -> raise "must not classify filing buckets" end

      assert %{bucket: :filing} =
               PageTreeProjection.classify("Incident 13/07/2022", "2022", "body", gen_fun: boom)

      assert %{bucket: :filing} =
               PageTreeProjection.classify("Template VPN", "TEMPLATES", "body", gen_fun: boom)
    end

    test "derives document-about only when the parent entity is grounded" do
      json =
        ~s({"bucket":"documents","confirm":true,"parent_entity":"Antivirus Eset","evidence":"procedure applies to Antivirus Eset"})

      assert %{bucket: :documents, parent_entity: "Antivirus Eset"} =
               PageTreeProjection.classify(
                 "Deploy ESET",
                 "Antivirus Eset",
                 "Procedure for Antivirus Eset deployment.",
                 gen_fun: gen(json)
               )

      ungrounded =
        ~s({"bucket":"documents","confirm":true,"parent_entity":"Ghost","evidence":"procedure applies to Ghost"})

      assert %{bucket: :none} =
               PageTreeProjection.classify("Deploy ESET", "Antivirus Eset", "Procedure.",
                 gen_fun: gen(ungrounded)
               )
    end

    test "promotes part_of only with conservative confirm and positive grounded body evidence" do
      body = "NGINX Ingress Controller is a component of K8s and handles cluster ingress."

      json =
        ~s({"bucket":"part_of","confirm":true,"child_entity":"NGINX Ingress Controller","parent_entity":"K8s","evidence":"NGINX Ingress Controller is a component of K8s"})

      assert %{bucket: :part_of} =
               PageTreeProjection.classify("NGINX Ingress Controller", "K8s", body,
                 gen_fun: gen(json)
               )

      no_body_evidence =
        ~s({"bucket":"part_of","confirm":true,"child_entity":"NGINX Ingress Controller","parent_entity":"K8s","evidence":"page is under K8s"})

      assert %{bucket: :none} =
               PageTreeProjection.classify(
                 "NGINX Ingress Controller",
                 "K8s",
                 "Operational notes for NGINX Ingress Controller.",
                 gen_fun: gen(no_body_evidence)
               )

      doubt =
        ~s({"bucket":"part_of","confirm":false,"child_entity":"NGINX Ingress Controller","parent_entity":"K8s","evidence":"component of"})

      assert %{bucket: :none} =
               PageTreeProjection.classify("NGINX Ingress Controller", "K8s", body,
                 gen_fun: gen(doubt)
               )
    end
  end

  describe "write/4" do
    test "document-about emits documents and applies_to from the page node and leaves child_of intact" do
      node = source_node()
      parent = Store.upsert_node("article", "Antivirus Eset", scope: test_src())
      {:ok, _} = Store.add_edge(node.id, parent, "child_of", "tree-prov", scope: test_src())

      ids =
        PageTreeProjection.write(
          node,
          %{
            bucket: :documents,
            child_entity: nil,
            parent_entity: "Antivirus Eset",
            evidence: "grounded"
          },
          "projection-prov"
        )

      assert length(ids) == 2

      assert Repo.query!(
               "SELECT e.type, s.type, s.key, d.type, d.key FROM edge e " <>
                 "JOIN node s ON s.id = e.src JOIN node d ON d.id = e.dst ORDER BY e.type"
             ).rows == [
               ["applies_to", "article", "child-page", "entity", "antivirus eset"],
               ["child_of", "article", "child-page", "article", "Antivirus Eset"],
               ["documents", "article", "child-page", "entity", "antivirus eset"]
             ]
    end

    test "part_of emits only entity-to-entity with derived evidence" do
      node = source_node()
      Store.upsert_node("entity", "nginx ingress controller", scope: test_src())
      Store.upsert_node("entity", "k8s", scope: test_src())

      ids =
        PageTreeProjection.write(
          node,
          %{
            bucket: :part_of,
            child_entity: "NGINX Ingress Controller",
            parent_entity: "K8s",
            evidence: "NGINX Ingress Controller is a component of K8s"
          },
          "projection-prov"
        )

      assert [_] = ids

      assert Repo.query!(
               "SELECT e.type, e.evidence_kind, s.type, s.key, d.type, d.key, e.visibility_scope " <>
                 "FROM edge e JOIN node s ON s.id = e.src JOIN node d ON d.id = e.dst"
             ).rows == [
               [
                 "part_of",
                 "derived",
                 "entity",
                 "nginx ingress controller",
                 "entity",
                 "k8s",
                 test_src()
               ]
             ]
    end

    test "part_of refuses to create entity nodes from classifier strings" do
      node = source_node()

      assert [] =
               PageTreeProjection.write(
                 node,
                 %{
                   bucket: :part_of,
                   child_entity: "NGINX Ingress Controller",
                   parent_entity: "K8s",
                   evidence: "NGINX Ingress Controller is a component of K8s"
                 },
                 "projection-prov"
               )

      assert Repo.query!("SELECT type, key FROM node ORDER BY id").rows == [
               ["article", "child-page"]
             ]
    end

    test "non-promoted decisions write nothing" do
      assert [] = PageTreeProjection.write(source_node(), %{bucket: :filing}, "projection-prov")
      assert Repo.query!("SELECT count(*) FROM edge").rows == [[0]]
    end
  end
end
