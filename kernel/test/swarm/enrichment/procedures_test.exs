defmodule Swarm.Enrichment.ProceduresTest do
  @moduledoc """
  Procedure extraction (ADR-17 #2): the heuristic gate, the conservative/grounded parse, and
  the reorder-safe write that populates the tier-gate's `has_step` substrate.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.Procedures
  alias Swarm.Graph.Procedure
  alias Swarm.Graph.Store

  defp gen(json), do: fn _m, _p, _o -> {:ok, json} end

  defp src_node(scope),
    do: %{id: Store.upsert_node("article", "src-doc", scope: scope), scope: scope}

  describe "procedural?/1 (cheap gate)" do
    test "true on ordered / step / how-to signals" do
      assert Procedures.procedural?("1. do this\n2. do that")
      assert Procedures.procedural?("Step 1: open it. Step 2: close it.")
      assert Procedures.procedural?("How to reset your password")
      assert Procedures.procedural?("First open the portal, then set a password, finally save.")
    end

    test "false on plain prose (no 2nd LLM pass paid)" do
      refute Procedures.procedural?("The gateway is a Debian host that routes traffic.")
      refute Procedures.procedural?("")
      refute Procedures.procedural?(nil)
    end
  end

  describe "extract/2" do
    test "a non-procedural body never calls the model (gated)" do
      boom = fn _m, _p, _o -> raise "must not run the LLM on non-procedural text" end
      assert Procedures.extract("just some prose about servers", gen_fun: boom) == []
    end

    test "extracts a grounded, ordered procedure" do
      body = "How to reset: 1. open the portal 2. enter your login 3. set a new password"

      json =
        ~s({"procedures":[{"name":"reset password","steps":["open the portal","enter your login","set a new password"]}]})

      assert [%{name: "reset password", steps: steps}] =
               Procedures.extract(body, gen_fun: gen(json))

      assert steps == ["open the portal", "enter your login", "set a new password"]
    end

    test "drops steps NOT present in the passage (verbatim guard against invented steps)" do
      body = "How to reset: 1. open the portal 2. set a new password"
      # the model hallucinated a 'disable the firewall' step not in the body
      json =
        ~s({"procedures":[{"name":"reset","steps":["open the portal","disable the firewall","set a new password"]}]})

      assert [%{steps: steps}] = Procedures.extract(body, gen_fun: gen(json))
      assert steps == ["open the portal", "set a new password"]
    end

    test "drops a procedure with fewer than 2 grounded steps" do
      body = "How to reset: just open the portal."
      json = ~s({"procedures":[{"name":"reset","steps":["open the portal","invented step"]}]})
      assert Procedures.extract(body, gen_fun: gen(json)) == []
    end
  end

  describe "write/3 + Procedure.steps/3" do
    test "writes a procedure entity + ordered has_step→step edges, readable by the view" do
      n = src_node(test_src())
      procs = [%{name: "reset password", steps: ["open the portal", "set a new password"]}]
      ids = Procedures.write(n, procs, "enrich:node:#{n.id}")
      assert length(ids) == 2

      [%{origin: _, steps: steps}] = Procedure.steps("reset password", [test_src()])
      assert Enum.map(steps, & &1.key) == ["open the portal", "set a new password"]
      # steps are their OWN type, not concept (kept out of the synonymy/aggregation space)
      assert is_integer(node_id_of("step", "open the portal"))
      assert node_id_of("concept", "open the portal") == nil
    end

    test "a genuine REORDER re-inserts fresh ordinals (no stale-ordinal trap)" do
      n = src_node(test_src())
      prov = "enrich:node:#{n.id}"
      Procedures.write(n, [%{name: "p", steps: ["A", "B", "C"]}], prov)
      # re-enrich: same steps, new order A, C, B
      Procedures.write(n, [%{name: "p", steps: ["A", "C", "B"]}], prov)

      [%{steps: steps}] = Procedure.steps("p", [test_src()])
      assert Enum.map(steps, & &1.key) == ["A", "C", "B"]
      # exactly 3 has_step edges remain (no stale duplicates)
      assert length(steps) == 3
    end

    test "re-enrich with FEWER steps clears the dropped step" do
      n = src_node(test_src())
      prov = "enrich:node:#{n.id}"
      Procedures.write(n, [%{name: "p", steps: ["A", "B", "C"]}], prov)
      Procedures.write(n, [%{name: "p", steps: ["A", "B"]}], prov)

      [%{steps: steps}] = Procedure.steps("p", [test_src()])
      assert Enum.map(steps, & &1.key) == ["A", "B"]
    end
  end

  defp node_id_of(type, key) do
    case Swarm.Repo.query!("SELECT id FROM node WHERE type=$1 AND key=$2", [type, key]) do
      %{rows: [[id]]} -> id
      _ -> nil
    end
  end
end
