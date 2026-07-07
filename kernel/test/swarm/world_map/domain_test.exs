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
      refute Regex.match?(d.cue, "how do I reset my password")
      assert "carries" in d.relations
    end

    test "registry lookup" do
      assert Domain.get(:network).key == :network
      assert Domain.get(:nope) == nil
      assert Enum.any?(Domain.all(), &(&1.key == :network))
    end
  end

  describe "policy_filter/2 — global answer-time privacy chokepoint" do
    test "keeps only atoms the viewer's scopes allow" do
      atoms = [
        %{fact: "a", scope: "group"},
        %{fact: "b", scope: "private"},
        %{fact: "c", scope: "public"}
      ]

      kept = Domain.policy_filter(atoms, ["group", "public"])
      facts = Enum.map(kept, & &1.fact)
      assert "a" in facts
      assert "c" in facts
      refute "b" in facts
    end

    test "a scope-less atom is kept only when the viewer has group (conservative default)" do
      atoms = [%{fact: "x"}]
      assert Domain.policy_filter(atoms, ["group"]) == atoms
      assert Domain.policy_filter(atoms, ["public"]) == []
    end
  end
end
