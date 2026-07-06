defmodule Swarm.WorldMap.CoverageTest do
  @moduledoc """
  Tier-gate Stage-1 coverage (workspace ADR-17 Fork B). The deterministic structural
  gate: `describe/3` → `validate/1`. The load-bearing property is fail-closed —
  `validate/1` yields a `%Validated{}` ONLY for a blocker-free, citable, unambiguous
  descriptor; every other shape is `{:error, [blocker]}` ⇒ escalate. Pure (structure is
  injected), so async.
  """
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.Coverage
  alias Swarm.WorldMap.Coverage.Descriptor
  alias Swarm.WorldMap.Coverage.Validated

  # A fake Procedure.steps/3: ignores args, returns the configured variants.
  defp proc_fun(variants), do: fn _key, _scopes, _opts -> variants end

  defp variant(steps, opts \\ []) do
    %{
      origin: Keyword.get(opts, :origin, "wiki:secret-source-path"),
      steps: steps,
      has_generation_collision?: Keyword.get(opts, :collision?, false)
    }
  end

  defp step(ord, key), do: %{ordinal: ord, key: key}

  defp profile(groups), do: %{groups: groups, facts: [], claim_support: nil}

  defp group(pred, objects) do
    %{
      subject: "X",
      predicate: pred,
      objects:
        Enum.map(objects, fn {o, c} -> %{object: o, reliability: 1.0, corroboration: c} end),
      omitted: 0
    }
  end

  describe "describe/3 + validate/1 — procedure intent" do
    test "one clean variant ⇒ served, steps + opaque citation, NO raw origin" do
      v = variant([step(1, "open portal"), step(2, "set password")], origin: "wiki:reset-runbook")

      d =
        Coverage.describe("how do I reset my password", ["group"],
          candidate_keys: ["password reset"],
          procedure_fun: proc_fun([v]),
          profile: profile([])
        )

      assert %Descriptor{intent: :procedure, blockers: []} = d

      assert {:ok, %Validated{intent: :procedure, atoms: atoms, citations: cits}} =
               Coverage.validate(d)

      assert Enum.map(atoms, & &1.key) == ["open portal", "set password"]
      # opaque enumerated label — the raw origin must NOT travel with the answer
      assert cits == ["source-1"]
      refute Enum.any?(cits, &String.contains?(&1, "wiki"))
    end

    test "a generation collision ⇒ escalate (never serve a spliced procedure)" do
      v = variant([step(1, "a"), step(1, "b")], collision?: true)

      d =
        Coverage.describe("how to reset", ["group"],
          candidate_keys: ["reset"],
          procedure_fun: proc_fun([v]),
          profile: profile([])
        )

      assert d.blockers == [:generation_collision]
      assert {:error, [:generation_collision]} = Coverage.validate(d)
    end

    test "more than one variant (origins or entities) ⇒ ambiguous ⇒ escalate" do
      v1 = variant([step(1, "a")], origin: "wiki:a")
      v2 = variant([step(1, "b")], origin: "wiki:b")

      d =
        Coverage.describe("steps to configure", ["group"],
          candidate_keys: ["configure"],
          procedure_fun: proc_fun([v1, v2]),
          profile: profile([])
        )

      assert d.blockers == [:ambiguous_variants]
      assert {:error, [:ambiguous_variants]} = Coverage.validate(d)
    end

    test "distinct candidate procedures ⇒ picks the FIRST (ranked), serves — NOT ambiguous" do
      # two DIFFERENT procedure entities (candidate_keys ranked best-first); the gate must
      # serve the top match, not treat the second distinct procedure as an ambiguous variant.
      keyed = fn
        "proc-a", _s, _o -> [variant([step(1, "a1"), step(2, "a2")], origin: "wiki:a")]
        "proc-b", _s, _o -> [variant([step(1, "b1")], origin: "wiki:b")]
      end

      d =
        Coverage.describe("how do I do proc a", ["group"],
          candidate_keys: ["proc-a", "proc-b"],
          procedure_fun: keyed,
          profile: profile([])
        )

      assert %Descriptor{intent: :procedure, blockers: []} = d
      assert {:ok, %Validated{atoms: steps}} = Coverage.validate(d)
      assert Enum.map(steps, & &1.key) == ["a1", "a2"]
    end

    test "a procedure cue with NO clean variant ESCALATES (never a phantom serve)" do
      d =
        Coverage.describe("how do I reset the password", ["group"],
          candidate_keys: ["password reset"],
          procedure_fun: proc_fun([]),
          profile: profile([])
        )

      assert d.intent == :procedure
      assert {:error, [:no_candidate]} = Coverage.validate(d)
    end

    test "a procedure cue is NOT reclassified as an entity ask (intent split, code review)" do
      # cue present, no procedure variant, BUT entity coverage exists — must still
      # escalate, not serve entity facts for a "how do I" question.
      d =
        Coverage.describe("how do I reset the password", ["group"],
          candidate_keys: ["password reset"],
          procedure_fun: proc_fun([]),
          profile: profile([group("is_a", [{"a secret", 3}])])
        )

      assert d.intent == :procedure
      assert {:error, [:no_candidate]} = Coverage.validate(d)
    end
  end

  describe "describe/3 + validate/1 — entity_profile intent" do
    test "corroborated claim groups ⇒ served (counts as citations, no source identity)" do
      p = profile([group("is_a", [{"a load balancer", 2}]), group("runs_on", [{"k8s", 1}])])
      d = Coverage.describe("what is the ingress", ["group"], profile: p, entity_serve: true)

      assert %Descriptor{intent: :entity_profile, blockers: []} = d

      assert {:ok, %Validated{intent: :entity_profile, atoms: groups, citations: cits}} =
               Coverage.validate(d)

      assert length(groups) == 2
      assert Enum.all?(cits, &String.starts_with?(&1, "corroboration:"))
    end

    test "zero-corroboration groups ⇒ no citable source ⇒ escalate" do
      p = profile([group("is_a", [{"guess", 0}])])
      d = Coverage.describe("what is the ingress", ["group"], profile: p, entity_serve: true)

      assert d.blockers == [:no_corroboration]
      assert {:error, [:no_corroboration]} = Coverage.validate(d)
    end

    test "zero-corroboration OBJECTS are filtered out before serving (code review)" do
      # a group mixing a corroborated object with a bare guess — only the citable one
      # survives into the validated atoms; the uncitable guess is never served.
      p = profile([group("is_a", [{"a load balancer", 2}, {"a guess", 0}])])
      d = Coverage.describe("what is the ingress", ["group"], profile: p, entity_serve: true)

      assert {:ok, %Validated{atoms: [g]}} = Coverage.validate(d)
      assert Enum.map(g.objects, & &1.object) == ["a load balancer"]
    end

    test "a non-procedure query with entity coverage routes to entity_profile" do
      p = profile([group("is_a", [{"a database", 3}])])

      d =
        Coverage.describe("tell me about postgres", ["group"],
          candidate_keys: ["postgres"],
          # even if a procedure_fun would return a variant, no cue ⇒ not probed
          procedure_fun: proc_fun([variant([step(1, "x")])]),
          profile: p,
          entity_serve: true
        )

      assert d.intent == :entity_profile
      assert {:ok, %Validated{intent: :entity_profile}} = Coverage.validate(d)
    end

    test "entity coverage ESCALATES by default (entity_serve OFF — live false-serve guard)" do
      p = profile([group("is_a", [{"a database", 3}])])
      d = Coverage.describe("what is postgres", ["group"], profile: p)
      assert d.intent == :unknown
      assert {:error, [:unknown_intent]} = Coverage.validate(d)
    end
  end

  describe "fail-closed properties" do
    test "empty scopes ⇒ default-deny ⇒ escalate" do
      d = Coverage.describe("anything", [], candidate_keys: ["x"])
      assert d.blockers == [:empty_scopes]
      assert {:error, [:empty_scopes]} = Coverage.validate(d)
    end

    test "no structure at all ⇒ unknown ⇒ escalate" do
      d = Coverage.describe("what is X", ["group"], profile: profile([]))
      assert d.intent == :unknown
      assert {:error, [:unknown_intent]} = Coverage.validate(d)
    end

    test "ANY blocker present makes a Validated unrepresentable" do
      # sweep the blocker space: each must yield {:error, _}, never {:ok, _}
      for blockers <- [
            [:empty_scopes],
            [:unknown_intent],
            [:generation_collision],
            [:ambiguous_variants],
            [:no_candidate],
            [:no_corroboration]
          ] do
        d = %Descriptor{query: "q", intent: :procedure, blockers: blockers}
        assert {:error, ^blockers} = Coverage.validate(d)
      end
    end
  end
end
