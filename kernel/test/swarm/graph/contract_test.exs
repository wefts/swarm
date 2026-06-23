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
               Graph.add_edge(pub, priv, "mentions", "ev-1", scope: "group")

      assert edge_count() == 0
    end

    test "accepts an edge no wider than the narrowest endpoint" do
      a = add_node!(%{type: "file", scope: "group"})
      b = add_node!(%{type: "concept", scope: "public"})

      # group <= min(group, public) → allowed
      assert {:ok, _} = Graph.add_edge(a, b, "mentions", "ev-1", scope: "group")
      assert edge_count() == 1
    end

    test "rejects an edge to a non-existent endpoint (no scope to check)" do
      a = add_node!(%{type: "file", scope: "private"})

      assert {:error, {:contract, :unknown_endpoint}} =
               Graph.add_edge(a, 999_999, "mentions", "ev-1", scope: "private")

      assert edge_count() == 0
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
      assert {"is invalid", _} = cs.errors[:scope]
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

  describe "schema version" do
    test "is stamped, queryable, and matches the compiled contract" do
      assert Contract.stamped_version() == Contract.schema_version()
      assert Contract.schema_version() == 2
    end
  end

  describe "round-trip / compatibility" do
    test "a node written under the contract reads back intact" do
      id = add_node!(%{type: "concept", scope: "group", reliability: 0.7})

      %{rows: [[type, scope, rel]]} =
        Repo.query!("SELECT type, scope, reliability FROM node WHERE id = $1", [id])

      assert {type, scope, rel} == {"concept", "group", 0.7}
    end
  end
end
