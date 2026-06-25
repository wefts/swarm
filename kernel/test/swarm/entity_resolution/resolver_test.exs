defmodule Swarm.EntityResolution.ResolverTest do
  @moduledoc """
  Entity-resolution ER-3 — confirm + merge + driver. The LLM confirm is injected
  (`:confirm_fun`). The load-bearing test: merging two spellings of ONE origin does
  NOT inflate corroboration (the risk the whole epic was blocked on); a confirm-NO
  leaves distinct entities separate (no contamination).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.EntityResolution.Resolver
  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp dim, do: Swarm.Config.embedding_dim()
  defp unit(i), do: List.duplicate(0.0, dim()) |> List.replace_at(i, 1.0)

  defp entity(key, vec, scope \\ "public") do
    id = Store.upsert_node("entity", key, scope: scope)
    Repo.query!("UPDATE node SET vec = $2 WHERE id = $1", [id, Pgvector.new(vec)])
    id
  end

  defp yes, do: fn _pair -> true end
  defp no, do: fn _pair -> false end

  defp entity_count(key),
    do:
      (%{rows: [[n]]} =
         Repo.query!("SELECT count(*) FROM node WHERE type='entity' AND key=$1", [key])) && n

  describe "run_pass/1" do
    test "a confirmed pair is merged into one node" do
      entity("Apollo Program", unit(0))
      entity("Project Apollo", unit(0))

      assert %{proposed: 1, confirmed: 1, merged: 1} = Resolver.run_pass(confirm_fun: yes())

      # Exactly one of the two spellings survives; the other is folded.
      survivors = entity_count("Apollo Program") + entity_count("Project Apollo")
      assert survivors == 1
    end

    test "a rejected pair leaves distinct entities separate (no contamination)" do
      entity("Apollo Program", unit(0))
      entity("Project Apollo", unit(0))

      assert %{proposed: 1, confirmed: 0, merged: 0} = Resolver.run_pass(confirm_fun: no())
      assert entity_count("Apollo Program") == 1
      assert entity_count("Project Apollo") == 1
    end

    test "merging two spellings of ONE origin does NOT inflate corroboration (the blocked risk)" do
      target = add_node!(%{type: "concept", scope: "public"})
      a = entity("Apollo Program", unit(0))
      b = entity("Project Apollo", unit(0))

      # Both spellings assert the same fact about `target`, from the SAME origin
      # (one source spelled the entity two ways), distinct emission events.
      {:ok, _} =
        Store.add_edge(a, target, "landed_on", "p1",
          scope: "public",
          origin: "src-O",
          evidence_kind: "claim"
        )

      {:ok, _} =
        Store.add_edge(b, target, "landed_on", "p2",
          scope: "public",
          origin: "src-O",
          evidence_kind: "claim"
        )

      assert %{merged: 1} = Resolver.run_pass(confirm_fun: yes())

      # The two edges collapse to one (same natural key after merge); seen_count is
      # recomputed over DISTINCT origins → 1, NOT summed to 2. One source, one witness.
      %{rows: [[edges]]} = Repo.query!("SELECT count(*) FROM edge WHERE type = 'landed_on'")
      assert edges == 1

      %{rows: [[seen]]} = Repo.query!("SELECT seen_count FROM edge WHERE type = 'landed_on'")
      assert seen == 1
    end

    test "every decision is audited with non-sensitive features (no keys)" do
      entity("Apollo Program", unit(0))
      entity("Project Apollo", unit(0))

      Resolver.run_pass(confirm_fun: yes(), model: "test-model")

      %{rows: [[left, right, decision, into, model]]} =
        Repo.query!(
          "SELECT left_id, right_id, decision, into_id, model FROM entity_resolution_audit"
        )

      assert is_integer(left) and is_integer(right)
      assert decision == "confirmed_merged"
      assert is_integer(into)
      assert model == "test-model"

      # The audit schema has no key/content columns — content is never persisted.
      %{columns: cols} = Repo.query!("SELECT * FROM entity_resolution_audit LIMIT 0")
      refute "left_key" in cols
      refute "right_key" in cols
    end

    test "a rejected pair is audited as rejected (for threshold tuning)" do
      entity("Apollo Program", unit(0))
      entity("Project Apollo", unit(0))

      Resolver.run_pass(confirm_fun: no())

      %{rows: [[decision]]} = Repo.query!("SELECT decision FROM entity_resolution_audit")
      assert decision == "rejected"
    end

    test "merging two spellings of TWO independent origins keeps both witnesses" do
      target = add_node!(%{type: "concept", scope: "public"})
      a = entity("Apollo Program", unit(0))
      b = entity("Project Apollo", unit(0))

      {:ok, _} =
        Store.add_edge(a, target, "landed_on", "p1",
          scope: "public",
          origin: "src-1",
          evidence_kind: "claim"
        )

      {:ok, _} =
        Store.add_edge(b, target, "landed_on", "p2",
          scope: "public",
          origin: "src-2",
          evidence_kind: "claim"
        )

      assert %{merged: 1} = Resolver.run_pass(confirm_fun: yes())

      # Two genuinely independent origins survive the merge → seen_count 2.
      %{rows: [[seen]]} = Repo.query!("SELECT seen_count FROM edge WHERE type = 'landed_on'")
      assert seen == 2
    end
  end
end
