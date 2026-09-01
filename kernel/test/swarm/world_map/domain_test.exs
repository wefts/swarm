defmodule Swarm.WorldMap.DomainTest do
  @moduledoc "S3 serve-domain contract + global answer-time privacy filter. Pure — async."
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.Domain

  describe "the domain contract / registry" do
    test "the network domain declares its serve knobs" do
      d = Domain.network()
      assert d.key == :network
      assert d.min_corroboration == 2
      assert d.entail_system =~ "NETWORK TOPOLOGY"
      assert Regex.match?(d.cue, "what subnets does the orbit tunnel carry")
      assert Regex.match?(d.cue, "Яке публічне IP у nebula runners?")
      assert Regex.match?(d.cue, "які підмережі несе vpn тунель")
      refute Regex.match?(d.cue, "how do I reset my password")
      assert "carries" in d.relations
      assert "has_outbound_ip_address" in d.relations
    end

    test "the who (org-directory) domain declares its serve knobs" do
      d = Domain.who()
      assert d.key == :who

      # authoritative single source → serves on 1 (reconciliation, not corroboration, defends stale)
      assert d.min_corroboration == 1
      assert d.entail_system =~ "ORG-DIRECTORY"
      assert "managed_by" in d.relations
      assert "has_role_family" in d.relations
      assert "has_employment" in d.relations
      assert "member_of" in d.relations
      assert "works_in" in d.relations
      assert "managed_by_team" in d.relations
      # cue fires on who-questions...
      assert Regex.match?(d.cue, "who manages the platform team")
      assert Regex.match?(d.cue, "who is Jane Doe")
      assert Regex.match?(d.cue, "who's in the SRE team")
      # ...and now also on service-ownership verbs (E-service P1: services ride this same :who
      # path; `managed_by_team` is the governed relation that keeps this from over-answering).
      assert Regex.match?(d.cue, "who owns the keycloak service")
      assert Regex.match?(d.cue, "who runs gitlab")
      assert Regex.match?(d.cue, "who is responsible for ldap")
      assert Regex.match?(d.cue, "Хто керує командою platform?")
      assert Regex.match?(d.cue, "хто в команді platform")
      assert Regex.match?(d.cue, "керівник команди platform")
      refute Regex.match?(d.cue, "how do I reset my password")
    end

    test "registry lookup" do
      assert Domain.get(:network).key == :network
      assert Domain.get(:who).key == :who
      assert Domain.get(:nope) == nil
      assert Enum.any?(Domain.all(), &(&1.key == :network))
      assert Enum.any?(Domain.all(), &(&1.key == :who))
    end
  end

  describe "policy_filter/2 — global answer-time privacy chokepoint" do
    test "keeps only atoms the viewer's scopes allow" do
      atoms = [
        %{fact: "a", scope: Swarm.GraphCase.test_src()},
        %{fact: "b", scope: "private"},
        %{fact: "c", scope: "public"}
      ]

      kept = Domain.policy_filter(atoms, [Swarm.GraphCase.test_src(), "public"])
      facts = Enum.map(kept, & &1.fact)
      assert "a" in facts
      assert "c" in facts
      refute "b" in facts
    end

    test "a scope-less atom is DROPPED — default-deny, no default corpus scope (ADR-20)" do
      atoms = [%{fact: "x"}]
      assert Domain.policy_filter(atoms, [Swarm.GraphCase.test_src()]) == []
      assert Domain.policy_filter(atoms, ["public"]) == []
    end
  end
end
