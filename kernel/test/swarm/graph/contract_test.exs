defmodule Swarm.Graph.ContractTest do
  @moduledoc """
  swarm ADR-4: the graph schema is a write-validated public contract. These tests
  prove the asserted-malformed write paths are rejected fail-loud at the `Store`
  boundary (never silently stored), the scope vocabulary is enforced at the DB
  too (defense-in-depth), and the schema version is stamped. The write-time
  visibility invariant's durability gaps (concurrent re-scope, later narrowing)
  are documented limitations in ADR-4, not yet closed here.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Contract
  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp edge_count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM edge")
    n
  end

  describe "scope lattice helpers" do
    test "glb/2 returns the write-time clamp for endpoint scopes" do
      assert Contract.glb("public", "public") == "public"
      assert Contract.glb("src:wiki", "public") == "src:wiki"
      assert Contract.glb("src:wiki", "src:wiki") == "src:wiki"
      assert Contract.glb("src:wiki", "src:ldap") == "private"
      assert Contract.glb("private", "src:wiki") == "private"
    end

    test "lattice_leq/2 implements the partial order" do
      assert Contract.lattice_leq("private", "src:wiki")
      assert Contract.lattice_leq("src:wiki", "public")
      refute Contract.lattice_leq("src:wiki", "src:ldap")
      assert Contract.lattice_leq("src:wiki", "src:wiki")
      refute Contract.lattice_leq("public", "src:wiki")
    end

    test "valid_scope?/1 accepts base scopes and well-formed SOURCE-UUID scopes only (ADR-20 D2)" do
      assert Contract.valid_scope?("private")
      assert Contract.valid_scope?("public")
      assert Contract.valid_scope?(test_src())
      assert Contract.valid_scope?("src:0192aaaa-bbbb-7ccc-8ddd-eeeeffff0000")

      # a human label is NOT a security key — two Confluence connectors must not collide
      refute Contract.valid_scope?("src:wiki")
      refute Contract.valid_scope?("src:confluence")
      refute Contract.valid_scope?("src:a-b_1")
      # the transitional `group` scope is retired
      refute Contract.valid_scope?("group")
      refute Contract.valid_scope?("src:0192AAAA-BBBB-7CCC-8DDD-EEEEFFFF0000")
      refute Contract.valid_scope?("src:")
      refute Contract.valid_scope?("wiki")
      refute Contract.valid_scope?("")
      refute Contract.valid_scope?(123)
    end

    test "source_scope/1 and scope_source_id/1 round-trip a source id" do
      id = "0192aaaa-bbbb-7ccc-8ddd-eeeeffff0000"
      assert Contract.source_scope(id) == "src:" <> id
      assert Contract.scope_source_id("src:" <> id) == id
      assert Contract.scope_source_id("src:wiki") == nil
      assert Contract.scope_source_id("public") == nil
      assert Contract.source_scope?(test_src())
      refute Contract.source_scope?("src:wiki")
      assert_raise ArgumentError, fn -> Contract.source_scope("wiki") end
    end

    test "derived_origin?/1 — only enrich/synonymy origins inherit; content labels are not keys" do
      assert Contract.derived_origin?("enrich:origin:node:42")
      assert Contract.derived_origin?("synonymy")
      assert Contract.derived_origin?("synonymy:concept")
      refute Contract.derived_origin?("wiki:page:1")
      refute Contract.derived_origin?("ldap:directory")
      refute Contract.derived_origin?(123)
    end
  end

  describe "visibility invariant (ADR-5) enforced at the write boundary" do
    test "rejects an edge whose scope is wider than an endpoint — the leak path" do
      a = add_node!(%{type: "file", scope: "private"})
      b = add_node!(%{type: "concept", scope: "private"})

      assert {:error, {:contract, :scope_wider_than_endpoints}} =
               Graph.add_edge(a, b, "mentions", "ev-1", scope: "public")

      # and it was NOT stored
      assert edge_count() == 0
    end

    test "rejects when one endpoint is narrower than the asserted edge scope" do
      pub = add_node!(%{type: "file", scope: "public"})
      priv = add_node!(%{type: "concept", scope: "private"})

      assert {:error, {:contract, :scope_wider_than_endpoints}} =
               Graph.add_edge(pub, priv, "mentions", "ev-1", scope: test_src())

      assert edge_count() == 0
    end

    test "accepts an edge no wider than the narrowest endpoint" do
      a = add_node!(%{type: "file", scope: test_src()})
      b = add_node!(%{type: "concept", scope: "public"})

      # a source scope <= glb(source scope, public) → allowed
      assert {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-1", scope: test_src())
      assert edge_count() == 1
    end

    test "rejects an edge to a non-existent endpoint (no scope to check)" do
      a = add_node!(%{type: "file", scope: "private"})

      assert {:error, {:contract, :unknown_endpoint}} =
               Graph.add_edge(a, 999_999, "mentions", "ev-1", scope: "private")

      assert edge_count() == 0
    end

    test "accepts source-scoped nodes and clamps source-scoped edges by GLB" do
      assert Contract.validate_node(%{type: "article", scope: test_src()}) == :ok

      assert Contract.validate_edge(
               test_src(),
               test_src(),
               "mentions",
               test_src(),
               nil,
               "ev-1",
               "origin-1",
               "observation"
             ) == :ok

      assert Contract.validate_edge(
               test_src(),
               test_src(),
               "mentions",
               "public",
               nil,
               "ev-1",
               "origin-1",
               "observation"
             ) == {:error, :scope_wider_than_endpoints}
    end
  end

  describe "vocabulary + range validation on edges" do
    setup do
      %{
        a: add_node!(%{type: "file", scope: "private"}),
        b: add_node!(%{type: "concept", scope: "private"})
      }
    end

    test "rejects an unknown scope", %{a: a, b: b} do
      assert {:error, {:contract, :unknown_scope}} =
               Graph.add_edge(a, b, "mentions", "ev-1", scope: "secret")

      assert edge_count() == 0
    end

    test "rejects a malformed type", %{a: a, b: b} do
      assert {:error, {:contract, :invalid_type_format}} =
               Graph.add_edge(a, b, "Mentions", "ev-1", scope: "private")

      assert edge_count() == 0
    end

    test "rejects out-of-range reliability", %{a: a, b: b} do
      assert {:error, {:contract, :reliability_out_of_range}} =
               Graph.add_edge(a, b, "mentions", "ev-1", scope: "private", reliability: 1.5)

      assert edge_count() == 0
    end

    test "rejects a blank provenance key (shape only; lineage is ADR-9)", %{a: a, b: b} do
      assert {:error, {:contract, :blank_provenance}} =
               Graph.add_edge(a, b, "mentions", "   ", scope: "private")

      assert edge_count() == 0
    end
  end

  describe "governed relation endpoint kinds" do
    test "accepts a legal governed network relation" do
      host = add_node!(%{type: "entity", key: "net:host:web-a.example.test", scope: "public"})
      address = add_node!(%{type: "entity", key: "net:address:192.0.2.10", scope: "public"})

      assert {:ok, _} =
               Graph.add_edge(host, address, "has_public_address", "ev-net-1", scope: "public")

      assert edge_count() == 1
    end

    test "rejects an illegal governed network relation with a contract reason" do
      host = add_node!(%{type: "entity", key: "net:host:web-a.example.test", scope: "public"})

      service =
        add_node!(%{type: "entity", key: "net:service:frontend.example.test", scope: "public"})

      assert {:error,
              {:contract,
               {:relation_endpoint_kinds_mismatch,
                %{relation: "has_private_address", subject_kinds: subject_kinds}}}} =
               Graph.add_edge(host, service, "has_private_address", "ev-net-1", scope: "public")

      assert "host" in subject_kinds
      assert edge_count() == 0
    end

    test "keeps unknown relation names open" do
      host = add_node!(%{type: "entity", key: "net:host:web-a.example.test", scope: "public"})

      service =
        add_node!(%{type: "entity", key: "net:service:frontend.example.test", scope: "public"})

      assert {:ok, _} =
               Graph.add_edge(host, service, "connector_defined_relation", "ev-open-1",
                 scope: "public"
               )

      assert edge_count() == 1
    end

    test "treats article nodes as pages for page relation contracts" do
      article = add_node!(%{type: "article", key: "docs/page-a", scope: "public"})
      step = add_node!(%{type: "step", key: "docs/page-a#step-1", scope: "public"})

      assert {:ok, _} =
               Graph.add_edge(article, step, "has_step", "ev-page-1",
                 scope: "public",
                 step_ordinal: 1
               )

      assert edge_count() == 1
    end

    test "treats entity subjects as procedures only for has_step edges to step nodes" do
      procedure =
        add_node!(%{type: "entity", key: "reset example.test password", scope: "public"})

      step = add_node!(%{type: "step", key: "open the example.test portal", scope: "public"})

      concept =
        add_node!(%{
          type: "concept",
          key: "open the example.test portal concept",
          scope: "public"
        })

      assert {:ok, _} =
               Graph.add_edge(procedure, step, "has_step", "ev-proc-1",
                 scope: "public",
                 step_ordinal: 1
               )

      assert {:error,
              {:contract,
               {:relation_endpoint_kinds_mismatch,
                %{relation: "has_step", object_kinds: object_kinds}}}} =
               Graph.add_edge(procedure, concept, "has_step", "ev-proc-2",
                 scope: "public",
                 step_ordinal: 2
               )

      refute "step" in object_kinds
      assert edge_count() == 1
    end

    test "alias_of accepts the same inferred kind and rejects host-to-gateway aliases" do
      host_a = add_node!(%{type: "entity", key: "net:host:web-a.example.test", scope: "public"})
      host_b = add_node!(%{type: "entity", key: "net:host:web-b.example.test", scope: "public"})

      gateway =
        add_node!(%{type: "entity", key: "net:gateway:gateway-a.example.test", scope: "public"})

      assert {:ok, _} = Graph.add_edge(host_a, host_b, "alias_of", "ev-alias-1", scope: "public")

      assert {:error,
              {:contract,
               {:relation_endpoint_kinds_mismatch,
                %{relation: "alias_of", subject_kinds: subject_kinds, object_kinds: object_kinds}}}} =
               Graph.add_edge(host_a, gateway, "alias_of", "ev-alias-2", scope: "public")

      assert "host" in subject_kinds
      assert "gateway" in object_kinds
      assert edge_count() == 1
    end

    test "alias_of accepts deterministic bare IP and FQDN bridges to typed network keys" do
      bare_address = add_node!(%{type: "entity", key: "192.0.2.10", scope: "public"})
      typed_address = add_node!(%{type: "entity", key: "net:address:192.0.2.10", scope: "public"})
      bare_host = add_node!(%{type: "entity", key: "app01.example.test", scope: "public"})

      typed_host =
        add_node!(%{type: "entity", key: "net:host:app01.example.test", scope: "public"})

      assert {:ok, _} =
               Graph.add_edge(bare_address, typed_address, "alias_of", "ev-ip-1", scope: "public")

      assert {:ok, _} =
               Graph.add_edge(bare_host, typed_host, "alias_of", "ev-fqdn-1", scope: "public")

      assert edge_count() == 2
    end
  end

  describe "DB-level defense-in-depth (non-Store / raw-SQL writers)" do
    test "the scope vocabulary CHECK rejects an out-of-vocab node scope via raw SQL" do
      assert_raise Postgrex.Error, ~r/node_scope_vocab/, fn ->
        Repo.query!("INSERT INTO node (type, scope) VALUES ('file', 'secret')")
      end
    end
  end

  describe "node writes are validated" do
    test "add_node rejects an unknown scope (changeset)" do
      assert {:error, cs} = Graph.add_node(%{type: "file", scope: "secret"})
      refute cs.valid?
      # ADR-18: scope validated via Contract.valid_scope?/1 (base vocab OR src:* shape).
      assert {"is not an admissible scope", _} = cs.errors[:scope]
    end

    test "add_node accepts a well-formed src:* scope (changeset; ADR-18)" do
      assert {:ok, _} = Graph.add_node(%{type: "file", key: "src-scope-ok", scope: test_src()})
    end

    test "add_node rejects a malformed type (changeset)" do
      assert {:error, cs} = Graph.add_node(%{type: "File", scope: "private"})
      refute cs.valid?
    end

    test "upsert_node fails loud on a malformed type" do
      assert_raise Swarm.Graph.ContractError, ~r/graph contract/, fn ->
        Store.upsert_node("Bad-Type", "k1")
      end
    end

    test "upsert_node fails loud on an unknown scope" do
      assert_raise Swarm.Graph.ContractError, ~r/graph contract/, fn ->
        Store.upsert_node("file", "k1", scope: "secret")
      end
    end
  end

  describe "node-type vocabulary (swarm ADR-14 §3.1)" do
    test "upsert_node fails loud on a well-formed but out-of-vocabulary type" do
      assert "widget" not in Contract.types()

      assert_raise Swarm.Graph.ContractError, ~r/graph contract/, fn ->
        Store.upsert_node("widget", "k1")
      end
    end

    test "upsert_node accepts an in-vocabulary type" do
      assert is_integer(Store.upsert_node("article", "Some Page", scope: "public"))
    end

    test "add_node rejects an out-of-vocabulary type (changeset)" do
      assert {:error, cs} = Graph.add_node(%{type: "widget", scope: "private"})
      refute cs.valid?
      assert {"is invalid", _} = cs.errors[:type]
    end

    test "validate_node distinguishes unknown type from malformed type" do
      assert Contract.validate_node(%{type: "widget", scope: "private"}) ==
               {:error, :unknown_type}

      assert Contract.validate_node(%{type: "Bad-Type", scope: "private"}) ==
               {:error, :invalid_type_format}
    end

    test "edge/relation types stay an open set — a non-node type is still a valid edge" do
      a = add_node!(%{type: "article", key: "A", scope: "public"})
      b = add_node!(%{type: "article", key: "B", scope: "public"})

      # `links_to` is NOT in the node vocabulary, yet is a perfectly valid edge type.
      assert "links_to" not in Contract.types()
      assert {:ok, _} = Graph.add_edge(a, b, "links_to", "ev-1", scope: "public")
    end
  end

  describe "person-typed nodes are pinned private (person-scope-leak-guard)" do
    # ADR-16 step-7 review: the per-user chat-privacy leak rule rides the `private`
    # scope with no owner axis, so a `user` node written at any wider scope is a
    # leak path (a future enricher pointed at a person subject would surface their
    # facts at the source scope). The contract — not the caller — pins them.
    test "validate_node rejects a user node at any scope but private" do
      assert Contract.validate_node(%{type: "user", scope: test_src()}) ==
               {:error, :person_scope_not_private}

      assert Contract.validate_node(%{type: "user", scope: "public"}) ==
               {:error, :person_scope_not_private}

      assert Contract.validate_node(%{type: "user", scope: "private"}) == :ok
      # absent scope defaults to private — still admissible
      assert Contract.validate_node(%{type: "user"}) == :ok
    end

    test "upsert_node fails loud on a non-private user node" do
      assert_raise Swarm.Graph.ContractError, ~r/graph contract/, fn ->
        Store.upsert_node("user", "3f6c1b1e-0000-7000-8000-000000000001", scope: test_src())
      end
    end

    test "add_node rejects a non-private user node (changeset)" do
      assert {:error, cs} = Graph.add_node(%{type: "user", scope: "public"})
      refute cs.valid?
      assert {"person nodes are pinned private" <> _, _} = cs.errors[:scope]
    end

    test "a private user node writes fine, and non-user types keep wider scopes" do
      assert is_integer(
               Store.upsert_node("user", "3f6c1b1e-0000-7000-8000-000000000002", scope: "private")
             )

      assert is_integer(Store.upsert_node("article", "Wide Page", scope: "public"))
    end
  end

  describe "schema version" do
    test "is stamped, queryable, and matches the compiled contract" do
      assert Contract.stamped_version() == Contract.schema_version()
      assert Contract.schema_version() == 12
    end
  end

  describe "round-trip / compatibility" do
    test "a node written under the contract reads back intact" do
      id = add_node!(%{type: "concept", scope: test_src(), reliability: 0.7})

      %{rows: [[type, scope, rel]]} =
        Repo.query!("SELECT type, scope, reliability FROM node WHERE id = $1", [id])

      assert {type, scope, rel} == {"concept", test_src(), 0.7}
    end
  end
end
