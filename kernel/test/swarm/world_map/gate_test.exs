defmodule Swarm.WorldMap.GateTest do
  @moduledoc """
  The tier-routing gate `sufficient?/2` (workspace ADR-17 §3, Fork B). Stage 1
  (structural) then Stage 2 (entailment veto), composed fail-closed: only a blocker-free
  descriptor that ALSO passes the entailment veto serves; everything else escalates. The
  entailment veto is injected, so async + deterministic.
  """
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.Coverage
  alias Swarm.WorldMap.Coverage.Descriptor
  alias Swarm.WorldMap.Gate
  alias Swarm.WorldMap.Gate.Answer
  alias Swarm.WorldMap.Gate.Audit

  defp proc_fun(variants), do: fn _k, _s, _o -> variants end

  defp variant(steps, opts \\ []),
    do: %{
      origin: Keyword.get(opts, :origin, "wiki:x"),
      steps: steps,
      has_generation_collision?: Keyword.get(opts, :collision?, false)
    }

  defp step(o, k), do: %{ordinal: o, key: k}
  defp profile(groups), do: %{groups: groups, facts: [], claim_support: nil}

  defp group(pred, objs) do
    %{
      subject: "X",
      predicate: pred,
      omitted: 0,
      objects: Enum.map(objs, fn {o, c} -> %{object: o, reliability: 1.0, corroboration: c} end)
    }
  end

  defp clean_procedure do
    Coverage.describe("how do I reset my password", ["group"],
      candidate_keys: ["password reset"],
      procedure_fun: proc_fun([variant([step(1, "open portal"), step(2, "set password")])]),
      profile: profile([])
    )
  end

  defp always(bool), do: fn _q, _g -> bool end

  describe "sufficient?/2" do
    test "clean procedure + entailment YES ⇒ SERVE a struct (no rendered-string contract)" do
      assert {:serve, %Answer{} = ans, %Audit{decision: :serve, stage2: :yes, intent: :procedure}} =
               Gate.sufficient?(clean_procedure(), entail_fun: always(true))

      assert ans.intent == :procedure
      assert ans.text =~ "1. open portal"
      assert ans.text =~ "2. set password"
      assert ans.citations == ["source-1"]
      # opaque citation only — no raw origin leaks into the served answer
      refute ans.text =~ "wiki"
      refute Enum.any?(ans.citations, &String.contains?(&1, "wiki"))
    end

    test "clean procedure + entailment NO ⇒ ESCALATE (near-miss semantic guard)" do
      assert {:escalate, %Audit{decision: :escalate, stage2: :veto}} =
               Gate.sufficient?(clean_procedure(), entail_fun: always(false))
    end

    test "Stage-1 blocker ⇒ ESCALATE and Stage 2 is NOT consulted (veto-only asymmetry)" do
      d = %Descriptor{query: "q", intent: :procedure, blockers: [:generation_collision]}
      never = fn _q, _g -> raise "Stage 2 must not run after a Stage-1 rejection" end

      assert {:escalate,
              %Audit{decision: :escalate, blockers: [:generation_collision], stage2: nil}} =
               Gate.sufficient?(d, entail_fun: never)
    end

    test "an entailment error/timeout ⇒ ESCALATE (fail-closed)" do
      boom = fn _q, _g -> raise "model timeout" end

      assert {:escalate, %Audit{decision: :escalate, stage2: :error}} =
               Gate.sufficient?(clean_procedure(), entail_fun: boom)
    end

    test "corroborated entity coverage + entailment YES ⇒ SERVE (counts as citations)" do
      d =
        Coverage.describe("what is the ingress", ["group"],
          profile: profile([group("is_a", [{"a load balancer", 2}])])
        )

      assert {:serve, %Answer{intent: :entity_profile} = ans, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert ans.text =~ "is_a: a load balancer"
      assert Enum.all?(ans.citations, &String.starts_with?(&1, "corroboration:"))
    end

    test "a Stage-1 rejection is NEVER recovered by a YES entailment (asymmetry)" do
      # empty scopes ⇒ blocker; even a YES entailment cannot serve it
      d = Coverage.describe("anything", [], candidate_keys: ["x"])

      assert {:escalate, %Audit{blockers: [:empty_scopes]}} =
               Gate.sufficient?(d, entail_fun: always(true))
    end
  end
end
