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
  alias Swarm.WorldMap.Coverage.Validated

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
    Coverage.describe("how do I reset my password", [Swarm.GraphCase.test_src()],
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
      # chat-thread epic 2: for active_keys
      assert ans.key == "reset password procedure"
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
        Coverage.describe("what is the ingress", [Swarm.GraphCase.test_src()],
          profile: profile([group("is_a", [{"a load balancer", 2}])]),
          entity_serve: true
        )

      assert {:serve, %Answer{intent: :entity_profile} = ans, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert ans.text =~ "is_a: a load balancer"
      assert Enum.all?(ans.citations, &String.starts_with?(&1, "corroboration:"))
    end

    test "default procedure entail still uses the procedure system prompt" do
      parent = self()

      generation_fun = fn _model, _prompt, opts ->
        send(parent, {:system, Keyword.fetch!(opts, :system)})
        {:ok, ~s({"sufficient": true})}
      end

      assert {:serve, %Answer{intent: :procedure}, %Audit{stage2: :yes}} =
               Gate.sufficient?(clean_procedure(), generation_fun: generation_fun)

      assert_receive {:system, system}
      refute system == Gate.entity_entail_system()
      assert system =~ "PROCEDURE"
      assert system =~ "SAME operation"
    end

    test "default entity-profile entail uses the entity system prompt" do
      d =
        Coverage.describe("what is the ingress", [Swarm.GraphCase.test_src()],
          profile: profile([group("is_a", [{"a load balancer", 2}])]),
          entity_serve: true
        )

      parent = self()

      generation_fun = fn _model, _prompt, opts ->
        send(parent, {:system, Keyword.fetch!(opts, :system)})
        {:ok, ~s({"sufficient": true})}
      end

      assert {:serve, %Answer{intent: :entity_profile}, %Audit{stage2: :yes}} =
               Gate.sufficient?(d, generation_fun: generation_fun)

      assert_receive {:system, system}
      assert system == Gate.entity_entail_system()
      assert system =~ "ENTITY PROFILE FACTS"
      assert system =~ "DIRECT FACT"
      assert system =~ "broad profile request"
      assert system =~ "tell me about X"
      assert system =~ "розкажи про X"
      assert system =~ "що відомо про X"
      assert system =~ "direct profile facts"
      assert system =~ "specific missing"
      assert system =~ "Do not inherit or transfer attributes"
      assert system =~ "routes_to"
      assert system =~ "wrong entity"
      assert system =~ "wrong relation"
      assert system =~ "absent fact"
    end

    test "a Stage-1 rejection is NEVER recovered by a YES entailment (asymmetry)" do
      # empty scopes ⇒ blocker; even a YES entailment cannot serve it
      d = Coverage.describe("anything", [], candidate_keys: ["x"])

      assert {:escalate, %Audit{blockers: [:empty_scopes]}} =
               Gate.sufficient?(d, entail_fun: always(true))
    end
  end

  describe "served answers carry machine-readable provenance" do
    # A grader cannot tell a join from a coincidence by reading answer TEXT
    # (hive/docs/design/learner-eval-grading.md, fixture L1-concordance-ceiling). The
    # serve path already knows which graph objects it read; it just never said so.
    test "a neighborhood serve names the facts it was rendered from" do
      validated = %Validated{
        query: "which node runs app-01",
        intent: :neighborhood,
        domain: :network,
        name: "app-01",
        key: "net:host:site/app-01",
        atoms: [%{relation: "hosted_on", object: "hv-01", corroboration: 2}],
        citations: ["corroboration:2"]
      }

      answer = Gate.render(validated)

      assert answer.key == "net:host:site/app-01"
      assert answer.facts == validated.atoms
    end

    test "a procedure serve carries its steps as facts too" do
      validated = %Validated{
        query: "how do I rotate the key",
        intent: :procedure,
        name: "rotate the key",
        atoms: [%{ordinal: 1, key: "open the console"}],
        citations: ["source:1"]
      }

      assert Gate.render(validated).facts == validated.atoms
    end
  end

  describe "network intent" do
    defp net_desc(subject, facts, key \\ nil) do
      %Descriptor{
        query: "what subnets does #{subject} carry",
        intent: :neighborhood,
        domain: :network,
        neighborhood_subject: subject,
        neighborhood_key: key || subject,
        neighborhood_facts:
          Enum.map(facts, fn {r, o} ->
            %{
              relation: r,
              object: o,
              object_kind: "subnet",
              corroboration: 2,
              effective_reliability: 0.82,
              cardinality: Swarm.Graph.Network.cardinality(r)
            }
          end),
        blockers: []
      }
    end

    test "serves a network neighborhood when the entail veto passes" do
      d =
        net_desc(
          "tunnel orbit",
          [{"carries", "10.128.0.0/16"}, {"carries", "10.129.0.0/16"}],
          "net:tunnel:orbit"
        )

      assert {:serve,
              %Answer{
                intent: :neighborhood,
                domain: :network,
                text: text,
                citations: cits,
                key: key
              }, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "tunnel orbit"
      assert text =~ "carries 10.128.0.0/16"
      assert cits == ["corroboration:2"]
      # chat-thread epic 2: active_keys must echo the RAW key, never the display subject
      # (WhoMap/Network's subject_fun is a one-way display transform — not invertible).
      assert key == "net:tunnel:orbit"
    end

    test "renders deterministic network facts as answer prose and preserves citations" do
      d =
        net_desc(
          "host lyon",
          [
            {"has_private_address", "address/192.0.2.10"},
            {"has_public_address", "address/198.51.100.20"}
          ],
          "net:host:lyon"
        )

      assert {:serve,
              %Answer{
                text: text,
                citations: ["corroboration:2"]
              }, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "host lyon:"
      assert text =~ "Host lyon has private address 192.0.2.10."
      assert text =~ "Host lyon has public address 198.51.100.20."
      refute text =~ "has_private_address"
      refute text =~ "address/"
    end

    test "structured confidence varies with reliability and corroboration" do
      low =
        net_desc("host low", [{"has_private_address", "address/192.0.2.30"}], "net:host:low")

      high = %{
        low
        | neighborhood_facts: [
            %{
              relation: "has_private_address",
              object: "address/192.0.2.30",
              object_kind: "address",
              corroboration: 4,
              effective_reliability: 0.9,
              cardinality: :many
            }
          ]
      }

      assert {:serve, %Answer{confidence: low_conf}, _} =
               Gate.sufficient?(low, entail_fun: always(true))

      assert {:serve, %Answer{confidence: high_conf}, _} =
               Gate.sufficient?(high, entail_fun: always(true))

      assert low_conf < high_conf
      assert high_conf == 0.97
    end

    test "entail veto escalates (never serves the wrong-relation/entity)" do
      d = net_desc("tunnel conduit", [{"terminates_at", "gateway peer"}])

      assert {:escalate, %Audit{decision: :escalate, stage2: :veto}} =
               Gate.sufficient?(d, entail_fun: always(false))
    end

    test "default network entail still uses the domain system prompt" do
      d = net_desc("tunnel orbit", [{"carries", "10.128.0.0/16"}])
      parent = self()

      generation_fun = fn _model, _prompt, opts ->
        send(parent, {:system, Keyword.fetch!(opts, :system)})
        {:ok, ~s({"sufficient": true})}
      end

      assert {:serve, %Answer{intent: :neighborhood, domain: :network}, %Audit{stage2: :yes}} =
               Gate.sufficient?(d, generation_fun: generation_fun)

      assert_receive {:system, system}
      assert system == Swarm.WorldMap.Domain.network().entail_system
      refute system == Gate.entity_entail_system()
    end

    test "an empty network neighborhood cannot mint a Validated (fail-closed)" do
      d = %Descriptor{
        query: "q",
        intent: :neighborhood,
        domain: :network,
        neighborhood_facts: [],
        blockers: [:no_corroboration]
      }

      assert {:escalate, %Audit{blockers: [:no_corroboration]}} =
               Gate.sufficient?(d, entail_fun: always(true))
    end
  end

  describe "who intent (E1 org directory)" do
    defp who_desc(subject, facts, key \\ nil) do
      %Descriptor{
        query: "who is in #{subject}",
        intent: :neighborhood,
        domain: :who,
        neighborhood_subject: subject,
        neighborhood_key: key || subject,
        neighborhood_facts:
          Enum.map(facts, fn {r, o} ->
            %{
              relation: r,
              object: o,
              object_kind: "person",
              corroboration: 1,
              effective_reliability: 0.9,
              cardinality: :many
            }
          end),
        blockers: []
      }
    end

    test "serves a directory neighborhood when the entail veto passes (names, not uids)" do
      d =
        who_desc(
          "platform",
          [{"works_in", "Jane Doe"}, {"works_in", "Bob Smith"}],
          "who:team:platform"
        )

      assert {:serve,
              %Answer{intent: :neighborhood, domain: :who, text: text, citations: cits, key: key},
              %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "platform"
      assert text =~ "Platform works in Jane Doe and Bob Smith."
      assert cits == ["corroboration:1"]
      # chat-thread epic 2: active_keys must echo the RAW key, never the display subject
      assert key == "who:team:platform"
    end

    test "a person's served key is their uid, even though the display text names them (cn ≠ key)" do
      # `WhoMap.display_subject/1` resolves a PERSON to their `cn` for the header — a one-way
      # transform. If active_keys echoed "Jane Doe" back, no `who:person:*` lookup would ever
      # resolve it; the raw uid key must ride along instead (this is the exact live-verify gap).
      d = who_desc("Jane Doe", [{"works_in", "platform"}], "who:person:jdoe123")

      assert {:serve, %Answer{key: key, text: text}, %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "Jane Doe"
      assert key == "who:person:jdoe123"
    end

    test "entail veto escalates (never serves a different person/relation)" do
      d = who_desc("billing", [{"managed_by", "Wrong Person"}])

      assert {:escalate, %Audit{decision: :escalate, stage2: :veto}} =
               Gate.sufficient?(d, entail_fun: always(false))
    end

    test "an empty directory neighborhood cannot mint a Validated (fail-closed)" do
      d = %Descriptor{
        query: "q",
        intent: :neighborhood,
        domain: :who,
        neighborhood_facts: [],
        blockers: [:no_corroboration]
      }

      assert {:escalate, %Audit{blockers: [:no_corroboration]}} =
               Gate.sufficient?(d, entail_fun: always(true))
    end
  end

  describe "technology intent" do
    test "serves technology anchor facts as prose" do
      d = %Descriptor{
        query: "what is known about Magento?",
        intent: :neighborhood,
        domain: :technology,
        neighborhood_subject: "magento",
        neighborhood_key: "technology:magento",
        neighborhood_facts: [
          %{
            relation: "mentioned_in",
            object: "Magento operations",
            object_kind: "article",
            corroboration: 1,
            effective_reliability: 0.72,
            cardinality: :many
          }
        ],
        blockers: []
      }

      assert {:serve, %Answer{intent: :neighborhood, domain: :technology, text: text, key: key},
              %Audit{decision: :serve}} =
               Gate.sufficient?(d, entail_fun: always(true))

      assert text =~ "magento:"
      assert text =~ "Magento mentioned in Magento operations."
      assert key == "technology:magento"
    end
  end
end
