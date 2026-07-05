defmodule Swarm.Graph.ProcedureTest do
  @moduledoc """
  Procedure aggregation (workspace ADR-17 §1–2): a "how do I X" procedure rebuilt at
  read time from ordered `has_step` claim-edges on an `entity` node — grouped by
  origin, ordered by step_ordinal within origin (never interleaving two sources'
  steps), scope-enforced, refuted excluded.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Procedure
  alias Swarm.Graph.Store

  defp ent(key, scope), do: Store.upsert_node("entity", key, scope: scope)
  defp step_node(key, scope), do: Store.upsert_node("concept", key, scope: scope)

  defp has_step(proc, step, ordinal, origin, scope) do
    {:ok, _} =
      Store.add_edge(proc, step, "has_step", origin,
        scope: scope,
        origin: origin,
        evidence_kind: "claim",
        step_ordinal: ordinal
      )
  end

  describe "steps/3" do
    test "reconstructs an ordered procedure from one source" do
      p = ent("password reset", "group")
      s1 = step_node("open the portal", "group")
      s2 = step_node("enter your login", "group")
      s3 = step_node("set a new password", "group")
      # inserted out of order — the view must sort by ordinal
      has_step(p, s3, 3, "wiki:reset", "group")
      has_step(p, s1, 1, "wiki:reset", "group")
      has_step(p, s2, 2, "wiki:reset", "group")

      assert [%{origin: "wiki:reset", steps: steps}] =
               Procedure.steps("password reset", ["group"])

      assert Enum.map(steps, & &1.ordinal) == [1, 2, 3]

      assert Enum.map(steps, & &1.key) == [
               "open the portal",
               "enter your login",
               "set a new password"
             ]
    end

    test "groups by origin FIRST — two sources' steps never interleave" do
      p = ent("password reset", "group")
      a1 = step_node("A step one", "group")
      a2 = step_node("A step two", "group")
      b1 = step_node("B step one", "group")
      has_step(p, a1, 1, "wiki:a", "group")
      has_step(p, a2, 2, "wiki:a", "group")
      has_step(p, b1, 1, "wiki:b", "group")

      variants = Procedure.steps("password reset", ["group"])
      assert length(variants) == 2
      a = Enum.find(variants, &(&1.origin == "wiki:a"))
      b = Enum.find(variants, &(&1.origin == "wiki:b"))
      assert Enum.map(a.steps, & &1.key) == ["A step one", "A step two"]
      assert Enum.map(b.steps, & &1.key) == ["B step one"]
    end

    test "scope-enforced — a public-only reader gets nothing for a group procedure" do
      p = ent("password reset", "group")
      s = step_node("secret step", "group")
      has_step(p, s, 1, "wiki:reset", "group")

      assert Procedure.steps("password reset", ["public"]) == []
      assert Procedure.steps("password reset", ["group"]) != []
    end

    test "refuted step edges (reward<0) are excluded" do
      p = ent("password reset", "group")
      s = step_node("bad step", "group")
      has_step(p, s, 1, "wiki:reset", "group")
      %{rows: [[eid]]} = Swarm.Repo.query!("SELECT id FROM edge WHERE type='has_step' LIMIT 1")
      Store.set_reward(eid, -1.0)

      assert Procedure.steps("password reset", ["group"]) == []
    end

    test "an unknown or step-less entity yields no variants" do
      ent("empty concept", "group")
      assert Procedure.steps("empty concept", ["group"]) == []
      assert Procedure.steps("does not exist", ["group"]) == []
    end

    test "empty scopes ⇒ nothing (default-deny)" do
      assert Procedure.steps("password reset", []) == []
    end

    test "a step reinforced by a 2nd event of the same origin appears ONCE (code review)" do
      p = ent("password reset", "group")
      s = step_node("the one step", "group")
      has_step(p, s, 1, "wiki:reset", "group")
      # re-emit the SAME has_step edge with a fresh provenance under the same origin
      {:ok, _} =
        Store.add_edge(p, s, "has_step", "ev2",
          scope: "group",
          origin: "wiki:reset",
          evidence_kind: "claim",
          step_ordinal: 1
        )

      [%{origin: "wiki:reset", steps: steps}] = Procedure.steps("password reset", ["group"])
      assert length(steps) == 1
    end

    test "step_ordinal is NULLed for a non-has_step edge (write-boundary invariant)" do
      a = ent("A", "group")
      b = step_node("B", "group")
      {:ok, %{id: eid}} = Store.add_edge(a, b, "mentions", "ev", scope: "group", step_ordinal: 7)
      %{rows: [[ord]]} = Swarm.Repo.query!("SELECT step_ordinal FROM edge WHERE id = $1", [eid])
      assert ord == nil
    end
  end

  describe "has_generation_collision? (ADR-17 §2 Correction 3 — two-generation belt)" do
    test "a clean single-generation variant is NOT flagged" do
      p = ent("password reset", "group")
      s1 = step_node("open the portal", "group")
      s2 = step_node("enter your login", "group")
      has_step(p, s1, 1, "wiki:reset", "group")
      has_step(p, s2, 2, "wiki:reset", "group")

      [variant] = Procedure.steps("password reset", ["group"])
      assert variant.has_generation_collision? == false
    end

    test "a re-ingested page (two distinct steps share an ordinal within one origin) IS flagged" do
      # Residual #2 / gemini Correction 3: a re-ingest leaves OLD+NEW has_step edges
      # under the SAME origin until GC. Distinct step TEXT at the same ordinal ⇒ the
      # ordering would splice generations (1,1,2,2). The view must flag it so the gate
      # escalates — never serve a spliced procedure even if GC is delayed.
      p = ent("password reset", "group")
      # generation 1 (original page)
      has_step(p, step_node("old: open portal", "group"), 1, "wiki:reset", "group")
      has_step(p, step_node("old: enter login", "group"), 2, "wiki:reset", "group")
      # generation 2 (re-ingested, changed page — new step text, same ordinals/origin)
      has_step(p, step_node("new: open portal v2", "group"), 1, "wiki:reset", "group")
      has_step(p, step_node("new: enter login v2", "group"), 2, "wiki:reset", "group")

      [variant] = Procedure.steps("password reset", ["group"])
      assert variant.origin == "wiki:reset"
      assert variant.has_generation_collision? == true
    end

    test "collision is per-origin — a clean origin is not tainted by a collided sibling" do
      p = ent("password reset", "group")
      # clean origin
      has_step(p, step_node("A step one", "group"), 1, "wiki:a", "group")
      has_step(p, step_node("A step two", "group"), 2, "wiki:a", "group")
      # collided origin (two texts at ordinal 1)
      has_step(p, step_node("B step one", "group"), 1, "wiki:b", "group")
      has_step(p, step_node("B step one v2", "group"), 1, "wiki:b", "group")

      variants = Procedure.steps("password reset", ["group"])
      a = Enum.find(variants, &(&1.origin == "wiki:a"))
      b = Enum.find(variants, &(&1.origin == "wiki:b"))
      assert a.has_generation_collision? == false
      assert b.has_generation_collision? == true
    end
  end
end
