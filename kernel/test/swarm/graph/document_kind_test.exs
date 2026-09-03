defmodule Swarm.Graph.DocumentKindTest do
  use ExUnit.Case, async: true

  alias Swarm.Graph.DocumentKind

  test "classifies deterministic policy, procedure, incident, reference, and unknown hints" do
    assert DocumentKind.classify(%{
             title: "AI Tools Governance Policy",
             body: "Approval and review terms for example.test tools."
           }) == :policy

    assert DocumentKind.classify(%{
             title: "Install Example Service",
             body: "Procedure: step 1 configure the TEST-NET endpoint."
           }) == :procedure

    assert DocumentKind.classify(%{
             title: "Example Service Outage Postmortem",
             body: "CRI remediation notes."
           }) == :incident

    assert DocumentKind.classify(%{
             title: "Example Service Reference",
             body: "Known facts and glossary entries."
           }) == :reference

    assert DocumentKind.classify(%{title: "Example Notes", body: "General background."}) ==
             :unknown
  end

  test "uses structural has_step evidence as a procedure hint without writing truth" do
    assert DocumentKind.classify(%{
             title: "Example Service",
             body: "Generic page.",
             structural_evidence: [%{relation: "has_step"}]
           }) == :procedure
  end

  test "infers query kind only from explicit shape cues" do
    assert DocumentKind.query_kind("what is the approval policy for example.test AI tools") ==
             :policy

    assert DocumentKind.query_kind("how do I install the example.test agent") == :procedure
    assert DocumentKind.query_kind("summarize the CRI outage") == :incident
    assert DocumentKind.query_kind("what is known about example.test") == :reference
    assert DocumentKind.query_kind("tell me about example.test") == :unknown
  end

  test "finds named subject hits by high title-token coverage across surrounding language" do
    hits = [
      %{id: 1, type: "page", key: "Example.test AI Solution"},
      %{id: 2, type: "page", key: "Install Example.test Certificate"},
      %{id: 3, type: "page", key: "Example.test DevOps Notes"},
      %{id: 4, type: "page", key: "Example.test Solution AI"}
    ]

    assert [%{key: "Example.test AI Solution"}] =
             DocumentKind.named_subject_hits("розкажи про Example.test AI Solution", hits)

    assert DocumentKind.named_subject_hits("розкажи про Example.test", hits) == []
  end

  test "uses explicit title metadata before key for named subject matching" do
    hits = [
      %{id: 1, type: "page", title: "Example.test AI Solution", key: "doc-123"},
      %{id: 2, type: "page", title: "Example.test Procedure", key: "doc-456"}
    ]

    assert [%{key: "doc-123"}] =
             DocumentKind.named_subject_hits("tell me about Example.test AI Solution", hits)
  end

  test "does not treat generic two-token titles as named subjects" do
    hits = [
      %{id: 1, type: "page", key: "Public IP"},
      %{id: 2, type: "page", key: "Example.test Galaxy Runners"}
    ]

    assert [%{key: "Example.test Galaxy Runners"}] =
             DocumentKind.named_subject_hits(
               "which public IP is associated with Example.test Galaxy runners",
               hits
             )
  end
end
