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
      candidate_keys: ["reset password procedure"],
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
      # the served answer + the entail grounding carry the procedure NAME (go/no-go tuning)
      assert ans.text =~ "reset password procedure"
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
          profile: profile([group("is_a", [{"a load balancer", 2}])]),
          entity_serve: true
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

  describe "network intent" do
    defp net_desc(subject, facts) do
      %Descriptor{
        query: "what subnets does #{subject} carry",
        intent: :network,
        network_subject: subject,
        network_facts:
          Enum.map(facts, fn {r, o} -> %{relation: r, object: o, object_kind: "subnet", corroboration: 2} end),
        blockers: []
      }
    end

    test "serves a network neighborhood when the entail veto passes" do
      d = net_desc("tunnel orbit", [{"carries", "10.128.0.0/16"}, {"carries", "10.129.0.0/16"}])

      assert {:serve, %Answer{intent: :network, text: text, citations: cits}, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "tunnel orbit"
      assert text =~ "carries 10.128.0.0/16"
      assert cits == ["corroboration:2"]
    end

    test "entail veto escalates (never serves the wrong-relation/entity)" do
      d = net_desc("tunnel conduit", [{"terminates_at", "gateway peer"}])
      assert {:escalate, %Audit{decision: :escalate, stage2: :veto}} =
               Gate.sufficient?(d, entail_fun: always(false))
    end

    test "an empty network neighborhood cannot mint a Validated (fail-closed)" do
      d = %Descriptor{query: "q", intent: :network, network_facts: [], blockers: [:no_corroboration]}
      assert {:escalate, %Audit{blockers: [:no_corroboration]}} =
               Gate.sufficient?(d, entail_fun: always(true))
    end
  end

  describe "who intent (E1 org directory)" do
    defp who_desc(subject, facts) do
      %Descriptor{
        query: "who is in #{subject}",
        intent: :who,
        who_subject: subject,
        who_facts:
          Enum.map(facts, fn {r, o} -> %{relation: r, object: o, object_kind: "person", corroboration: 1} end),
        blockers: []
      }
    end

    test "serves a directory neighborhood when the entail veto passes (names, not uids)" do
      d = who_desc("platform", [{"works_in", "Jane Doe"}, {"works_in", "Bob Smith"}])

      assert {:serve, %Answer{intent: :who, text: text, citations: cits}, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "platform"
      assert text =~ "works_in Jane Doe"
      assert cits == ["corroboration:1"]
    end

    test "entail veto escalates (never serves a different person/relation)" do
      d = who_desc("billing", [{"managed_by", "Wrong Person"}])
      assert {:escalate, %Audit{decision: :escalate, stage2: :veto}} =
               Gate.sufficient?(d, entail_fun: always(false))
    end

    test "an empty directory neighborhood cannot mint a Validated (fail-closed)" do
      d = %Descriptor{query: "q", intent: :who, who_facts: [], blockers: [:no_corroboration]}
      assert {:escalate, %Audit{blockers: [:no_corroboration]}} =
               Gate.sufficient?(d, entail_fun: always(true))
    end
  end
end
