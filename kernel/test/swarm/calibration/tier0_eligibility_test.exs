defmodule Swarm.Calibration.Tier0EligibilityTest do
  use Swarm.GraphCase, async: false

  alias Swarm.AnswerRecords
  alias Swarm.Calibration.{Contradictions, Tier0Eligibility}
  alias Swarm.Enrichment.NetworkMap
  alias Swarm.Graph.Store
  alias Swarm.WorldMap.{Coverage, Gate}

  @scope Swarm.GraphCase.test_src()

  defp source(key), do: %{id: Store.upsert_node("article", key, scope: @scope), scope: @scope}

  defp seed_address(provenance, origin) do
    NetworkMap.write(
      source("source-#{provenance}"),
      [
        %{
          subject: "example-host",
          subject_kind: "host",
          relation: "has_address",
          object: "10.20.30.1",
          object_kind: "address"
        }
      ],
      provenance,
      origin: origin
    )
  end

  defp descriptor do
    Coverage.describe("What is private IP of example-host?", [@scope],
      network_keys: ["net:host:example-host"],
      network_serve: true,
      semantic_route: {:neighborhood, :network},
      network_min_corroboration: 1
    )
  end

  defp validated do
    {:ok, v} = Coverage.validate(descriptor())
    v
  end

  defp record_high_agreement do
    AnswerRecords.maybe_persist(
      "alice",
      [@scope],
      "What is private IP of example-host?",
      %{
        answer: "has_private_address 10.20.30.1",
        confidence: 0.8,
        tier: "escalate",
        status: :found,
        agreement: 0.91,
        citations: [%{source: "structured", ref: "net:host:example-host", confidence: 1.0}]
      }
    )
  end

  test "eligible when corroborated, not contradicted, high-agreement, and uniquely resolved" do
    seed_address("prov-a", "wiki")
    seed_address("prov-b", "iac")
    record_high_agreement()

    assert Tier0Eligibility.eligible?(validated(), scopes: [@scope])
  end

  test "not eligible with only one corroborating origin" do
    seed_address("prov-a", "wiki")
    record_high_agreement()

    refute Tier0Eligibility.eligible?(validated(), scopes: [@scope])
  end

  test "not eligible when a contradiction is recorded" do
    seed_address("prov-a", "wiki")
    seed_address("prov-b", "iac")
    record_high_agreement()

    Contradictions.persist(%{
      ask_ref: "contradiction-ref",
      verdict: :contradicted,
      relation: "has_private_address",
      subject: "net:host:example-host",
      explanation: "synthetic contradiction"
    })

    refute Tier0Eligibility.eligible?(validated(), scopes: [@scope])
  end

  test "not eligible when high agreement is for another relation" do
    seed_address("prov-a", "wiki")
    seed_address("prov-b", "iac")

    AnswerRecords.maybe_persist(
      "alice",
      [@scope],
      "What routes via example-host?",
      %{
        answer: "routes_via gateway example",
        confidence: 0.8,
        tier: "escalate",
        status: :found,
        agreement: 0.91,
        citations: [%{source: "structured", ref: "net:host:example-host", confidence: 1.0}]
      }
    )

    refute Tier0Eligibility.eligible?(validated(), scopes: [@scope])
  end

  test "not eligible when the high-agreement answer had scopes not covered now" do
    seed_address("prov-a", "wiki")
    seed_address("prov-b", "iac")

    AnswerRecords.maybe_persist(
      "alice",
      [@scope, Swarm.GraphCase.test_src2()],
      "What is private IP of example-host?",
      %{
        answer: "has_private_address 10.20.30.1",
        confidence: 0.8,
        tier: "escalate",
        status: :found,
        agreement: 0.91,
        citations: [%{source: "structured", ref: "net:host:example-host", confidence: 1.0}]
      }
    )

    refute Tier0Eligibility.eligible?(validated(), scopes: [@scope])
  end

  test "eligible structured network facts bypass Stage 2; ineligible facts still need it" do
    seed_address("prov-a", "wiki")

    assert {:escalate, _audit} =
             Gate.sufficient?(descriptor(),
               scopes: [@scope],
               generation_fun: fn _model, _prompt, _opts -> {:ok, ~s({"sufficient": false})} end
             )

    seed_address("prov-b", "iac")
    record_high_agreement()

    assert {:serve, _answer, audit} =
             Gate.sufficient?(descriptor(),
               scopes: [@scope],
               generation_fun: fn _model, _prompt, _opts ->
                 raise "eligible facts must not call Stage 2"
               end
             )

    assert audit.stage2 == :yes
  end
end
