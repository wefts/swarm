defmodule Swarm.WorldMap.ServeCharacterizationTest do
  @moduledoc """
  CHARACTERIZATION ORACLE for E2b (`board/doing/e2b-domain-registry-design.md`, council
  must-do #4): pins the CURRENT byte-for-byte serve behavior of the world-map pipeline
  (`Swarm.WorldMap.Coverage.describe/3` → `validate/1` → `Swarm.WorldMap.Gate.sufficient?/2`)
  for the net/who/service neighborhood domains BEFORE the registry-collapse refactor.

  Do NOT change these assertions to match a refactor's "should be" behavior — they record
  what the code ACTUALLY does today. The refactor (E2b) must keep every test in this file
  green, unmodified. If a future PR needs to change one of these assertions, that is itself
  a behavior change and must be called out explicitly, not slipped in as part of E2b.

  Pins (per the council's must-dos):
    1. Cue precedence / routing order: procedure → who → network (checked in that order in
       `Coverage.describe/3`'s `cond`); a query matching multiple cues is routed by whichever
       branch is checked FIRST, not by "best match".
    2. Each neighborhood domain's `*_serve` flag defaults OFF (escalate) and must be
       explicitly opted in to serve.
    3. Blocker order: no candidate key ⇒ `:no_candidate`; a candidate with an empty
       neighborhood ⇒ `:no_corroboration`. Both escalate (fail-closed).
    4. Service-ownership queries ride the `:who` path (no separate `:service` intent exists
       today) via the who-cue's ownership verbs + the `managed_by_team` relation.
    5. Gate invariants: served answers carry only opaque `corroboration:N` citations (never
      raw origins/keys), and the Stage-2 entailment veto is fail-closed (any non-true / any
      raised error ⇒ escalate, never a recovered serve).
  """
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.Coverage
  alias Swarm.WorldMap.Coverage.Validated
  alias Swarm.WorldMap.Gate
  alias Swarm.WorldMap.Gate.Answer
  alias Swarm.WorldMap.Gate.Audit

  # --- shared injection helpers (same style as coverage_test.exs / gate_test.exs) ----------

  defp net_fun(facts), do: fn _key, _scopes, _opts -> facts end
  defp net_fact(rel, obj, corr \\ 2), do: %{relation: rel, object: obj, object_kind: "subnet", corroboration: corr}

  defp who_fun(facts), do: fn _key, _scopes, _opts -> facts end
  defp who_fact(rel, obj, corr \\ 1), do: %{relation: rel, object: obj, object_kind: "person", corroboration: corr}

  defp proc_fun(variants), do: fn _key, _scopes, _opts -> variants end

  defp profile(groups \\ []), do: %{groups: groups, facts: [], claim_support: nil}

  defp always(bool), do: fn _query, _grounding -> bool end

  # =========================================================================================
  # 1. CUE PRECEDENCE / ROUTING — procedure → who → network, in that fixed order
  # =========================================================================================

  describe "1. cue precedence / routing (pins the fixed branch order)" do
    test "a procedure cue wins even though a network cue ALSO matches ('configure the firewall')" do
      # "configure the firewall" matches BOTH the procedure cue (configure) and the network
      # cue (firewall). CURRENT behavior: the procedure branch is checked first ⇒ :procedure,
      # even with network_serve on and a network candidate that WOULD have served.
      d =
        Coverage.describe("how do I configure the firewall", ["group"],
          candidate_keys: [],
          procedure_fun: fn _, _, _ -> [] end,
          network_serve: true,
          network_keys: ["net:firewall:edge"],
          network_fun: net_fun([net_fact("protected_by", "edge-fw")])
        )

      assert d.intent == :procedure
      assert d.blockers == [:no_candidate]
      assert {:error, [:no_candidate]} = Coverage.validate(d)
    end

    test "a who-cue about network gear wins over the network cue ('who manages the firewall')" do
      # "who manages the firewall" matches the who-cue ("who manages") AND the network cue
      # ("firewall"). CURRENT behavior: who is checked BEFORE network ⇒ :who wins.
      d =
        Coverage.describe("who manages the firewall", ["group"],
          who_serve: true,
          who_keys: ["who:person:admin"],
          who_fun: who_fun([who_fact("managed_by", "Ann Ops")]),
          network_serve: true,
          network_keys: ["net:firewall:edge"],
          network_fun: net_fun([net_fact("protected_by", "edge-fw")])
        )

      assert d.intent == :neighborhood
      assert d.domain == :who
      assert d.neighborhood_subject != nil
      assert {:ok, %Validated{intent: :neighborhood, domain: :who}} = Coverage.validate(d)
    end

    test "a bare network query (no procedure/who cue) routes to :network" do
      d =
        Coverage.describe("what subnets does the orbit tunnel carry", ["group"],
          network_serve: true,
          network_keys: ["net:tunnel:orbit"],
          network_fun: net_fun([net_fact("carries", "10.128.0.0/16"), net_fact("carries", "10.129.0.0/16")])
        )

      assert d.intent == :neighborhood
      assert d.domain == :network
      assert d.neighborhood_subject == "tunnel orbit"
      assert {:ok, %Validated{intent: :neighborhood, domain: :network}} = Coverage.validate(d)
    end
  end

  # =========================================================================================
  # 2. SERVE FLAGS — off by default (escalate), explicit opt-in serves
  # =========================================================================================

  describe "2. serve flags (default OFF ⇒ escalate; explicit true ⇒ serve)" do
    test "who_serve false (default) ⇒ a matching who query is :unknown / escalate" do
      d =
        Coverage.describe("who manages the platform team", ["group"],
          who_keys: ["who:team:platform"],
          who_fun: who_fun([who_fact("managed_by", "Jane Doe")])
        )

      assert d.intent == :unknown
      assert {:error, [:unknown_intent]} = Coverage.validate(d)
    end

    test "who_serve true ⇒ the SAME query serves" do
      d =
        Coverage.describe("who manages the platform team", ["group"],
          who_serve: true,
          who_keys: ["who:team:platform"],
          who_fun: who_fun([who_fact("managed_by", "Jane Doe")])
        )

      assert d.intent == :neighborhood
      assert d.domain == :who
      assert {:ok, %Validated{intent: :neighborhood, domain: :who}} = Coverage.validate(d)
    end

    test "network_serve false (default) ⇒ a matching network query is :unknown / escalate" do
      d =
        Coverage.describe("what subnets does the orbit tunnel carry", ["group"],
          network_keys: ["net:tunnel:orbit"],
          network_fun: net_fun([net_fact("carries", "10.0.0.0/8")])
        )

      assert d.intent == :unknown
      assert {:error, [:unknown_intent]} = Coverage.validate(d)
    end

    test "network_serve true ⇒ the SAME query serves" do
      d =
        Coverage.describe("what subnets does the orbit tunnel carry", ["group"],
          network_serve: true,
          network_keys: ["net:tunnel:orbit"],
          network_fun: net_fun([net_fact("carries", "10.128.0.0/16"), net_fact("carries", "10.129.0.0/16")])
        )

      assert d.intent == :neighborhood
      assert d.domain == :network
      assert {:ok, %Validated{intent: :neighborhood, domain: :network}} = Coverage.validate(d)
    end
  end

  # =========================================================================================
  # 3. BLOCKERS — no candidate ⇒ :no_candidate; candidate w/ empty neighborhood ⇒ :no_corroboration
  # =========================================================================================

  describe "3. blockers (fail-closed escalation reasons)" do
    test "network: no candidate keys ⇒ :no_candidate ⇒ escalate" do
      d =
        Coverage.describe("what subnets does the orbit tunnel carry", ["group"],
          network_serve: true,
          network_keys: [],
          network_fun: net_fun([])
        )

      assert d.blockers == [:no_candidate]
      assert {:error, [:no_candidate]} = Coverage.validate(d)
    end

    test "network: candidate present but empty neighborhood ⇒ :no_corroboration ⇒ escalate" do
      d =
        Coverage.describe("what subnets does the orbit tunnel carry", ["group"],
          network_serve: true,
          network_keys: ["net:tunnel:orbit"],
          network_fun: net_fun([])
        )

      assert d.blockers == [:no_corroboration]
      assert {:error, [:no_corroboration]} = Coverage.validate(d)
    end

    test "who: no candidate keys ⇒ :no_candidate ⇒ escalate" do
      d =
        Coverage.describe("who manages the platform team", ["group"],
          who_serve: true,
          who_keys: [],
          who_fun: who_fun([])
        )

      assert d.blockers == [:no_candidate]
      assert {:error, [:no_candidate]} = Coverage.validate(d)
    end

    test "who: candidate present but empty neighborhood ⇒ :no_corroboration ⇒ escalate" do
      d =
        Coverage.describe("who manages the platform team", ["group"],
          who_serve: true,
          who_keys: ["who:person:jdoe"],
          who_fun: who_fun([])
        )

      assert d.blockers == [:no_corroboration]
      assert {:error, [:no_corroboration]} = Coverage.validate(d)
    end
  end

  # =========================================================================================
  # 4. SERVICE-RIDES-WHO — no separate :service intent; ownership queries route via :who
  # =========================================================================================

  describe "4. service-rides-who (no distinct :service intent exists today)" do
    test "'who manages Keycloak' routes to :who (intent :who), not a separate :service intent" do
      d =
        Coverage.describe("who manages Keycloak", ["group"],
          who_serve: true,
          who_keys: ["who:service:keycloak"],
          who_fun: who_fun([who_fact("managed_by_team", "Platform Team")])
        )

      assert d.intent == :neighborhood
      assert d.domain == :who
      assert {:ok, %Validated{intent: :neighborhood, domain: :who} = validated} = Coverage.validate(d)
      assert Enum.any?(validated.atoms, &(&1.relation == "managed_by_team" and &1.object == "Platform Team"))
    end

    test "the served Answer for a service-ownership ask carries intent :who end to end" do
      d =
        Coverage.describe("who manages Keycloak", ["group"],
          who_serve: true,
          who_keys: ["who:service:keycloak"],
          who_fun: who_fun([who_fact("managed_by_team", "Platform Team")])
        )

      assert {:serve, %Answer{intent: :neighborhood, domain: :who, text: text, citations: cits},
              %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "managed_by_team Platform Team"
      assert cits == ["corroboration:1"]
    end
  end

  # =========================================================================================
  # 5. GATE INVARIANTS — opaque citations only; entail veto is fail-closed
  # =========================================================================================

  describe "5. gate invariants (opaque citations; fail-closed entail veto)" do
    test "a served network Answer carries only opaque corroboration:N citations, never raw keys" do
      d =
        Coverage.describe("what subnets does the orbit tunnel carry", ["group"],
          network_serve: true,
          network_keys: ["net:tunnel:orbit"],
          network_fun: net_fun([net_fact("carries", "10.128.0.0/16"), net_fact("carries", "10.129.0.0/16")])
        )

      assert {:serve, %Answer{citations: cits}, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert cits == ["corroboration:2"]
      refute Enum.any?(cits, &(&1 =~ ~r/net:|tunnel:|orbit/))
    end

    test "a served who Answer carries only opaque corroboration:N citations, never raw keys" do
      d =
        Coverage.describe("who is in the platform team", ["group"],
          who_serve: true,
          who_keys: ["who:team:platform"],
          who_fun: who_fun([who_fact("works_in", "Jane Doe"), who_fact("works_in", "Bob Smith")])
        )

      assert {:serve, %Answer{citations: cits}, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert cits == ["corroboration:1"]
      refute Enum.any?(cits, &(&1 =~ ~r/who:|team:|platform/))
    end

    test "entail veto (entail_fun returns false) escalates a structurally-valid network descriptor" do
      d =
        Coverage.describe("what subnets does the orbit tunnel carry", ["group"],
          network_serve: true,
          network_keys: ["net:tunnel:orbit"],
          network_fun: net_fun([net_fact("carries", "10.128.0.0/16"), net_fact("carries", "10.129.0.0/16")])
        )

      assert {:escalate, %Audit{decision: :escalate, stage2: :veto}} =
               Gate.sufficient?(d, entail_fun: always(false))
    end

    test "entail veto (entail_fun returns false) escalates a structurally-valid who descriptor" do
      d =
        Coverage.describe("who is in the platform team", ["group"],
          who_serve: true,
          who_keys: ["who:team:platform"],
          who_fun: who_fun([who_fact("works_in", "Jane Doe")])
        )

      assert {:escalate, %Audit{decision: :escalate, stage2: :veto}} =
               Gate.sufficient?(d, entail_fun: always(false))
    end

    test "an entail_fun that raises ⇒ escalate (fail-closed, never a crash-to-serve)" do
      boom = fn _q, _g -> raise "model timeout" end

      d =
        Coverage.describe("who is in the platform team", ["group"],
          who_serve: true,
          who_keys: ["who:team:platform"],
          who_fun: who_fun([who_fact("works_in", "Jane Doe")])
        )

      assert {:escalate, %Audit{decision: :escalate, stage2: :error}} =
               Gate.sufficient?(d, entail_fun: boom)
    end

    test "a Stage-1 blocker is never recovered by a YES entailment (asymmetry, procedure path)" do
      d =
        Coverage.describe("how do I reset my password", ["group"],
          candidate_keys: ["reset password"],
          procedure_fun: proc_fun([]),
          profile: profile()
        )

      assert {:escalate, %Audit{decision: :escalate, blockers: [:no_candidate]}} =
               Gate.sufficient?(d, entail_fun: always(true))
    end
  end
end
