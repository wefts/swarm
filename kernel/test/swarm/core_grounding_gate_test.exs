defmodule Swarm.CoreGroundingGateTest do
  @moduledoc """
  The grounding gate decides which retrieved pages reach the consilium prompt. Its
  minimum-keep pad must never admit zero-relevance tails (GLPI eval 70148: one relevant
  procedure page plus two zero-relevance sibling procedures produced a blended answer).
  """
  use ExUnit.Case, async: true

  alias Swarm.Core

  defp hit(key, relevance, id),
    do: %{id: id, type: "article", key: key, score: relevance, relevance: relevance, spans: []}

  @query "Quelle est la procédure suivie pour appliquer une mise à jour de sécurité de GitLab ?"

  test "a lone relevant page is not padded with zero-relevance siblings" do
    hits = [
      hit("GIT - Procédure de mise à jour", 0.6591, 1),
      hit("GLPI - Procédure de mise à jour", 0.0, 2),
      hit("Mise à jour Smilebuntu 20.04 vers 22.04", 0.0, 3),
      hit("Harbor mise à jour", 0.0, 4)
    ]

    assert Enum.map(Core.gate_grounding_hits(@query, hits), & &1.key) ==
             ["GIT - Procédure de mise à jour"]
  end

  test "the pad still keeps up to three pages when they carry some relevance" do
    hits = [
      hit("Alpha page", 0.6, 1),
      hit("Beta page", 0.1, 2),
      hit("Gamma page", 0.05, 3),
      hit("Delta page", 0.0, 4)
    ]

    # 0.1 and 0.05 are below the relative floor (0.24) but non-zero → padded in; 0.0 is not
    assert Enum.map(Core.gate_grounding_hits("what about alpha", hits), & &1.key) ==
             ["Alpha page", "Beta page", "Gamma page"]
  end

  test "hits above the relative floor are all kept; unscored hits pass through" do
    hits = [
      hit("One", 0.6, 1),
      hit("Two", 0.5, 2),
      hit("Three", 0.45, 3),
      hit("Four", 0.3, 4),
      %{id: 5, type: "entity", key: "net:host:x", score: 1.0, spans: []}
    ]

    assert Enum.map(Core.gate_grounding_hits("one two three four", hits), & &1.key) ==
             ["One", "Two", "Three", "Four", "net:host:x"]
  end
end
