defmodule Swarm.CoreTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Core
  alias Swarm.Gate.Bands

  defp ingest_public_files do
    event = fn key ->
      %{
        source: "t",
        provenance: key,
        occurred_at: DateTime.utc_now(),
        entities: [%{type: "file", key: key, scope: "public", content: "f"}],
        relations: []
      }
    end

    {:ok, :written} = Swarm.Ingest.ingest(event.("/docs/storage_engine.md"))
    {:ok, :written} = Swarm.Ingest.ingest(event.("/docs/billing_policy.md"))
  end

  # Force a tier by injecting the gate's embedder/prototypes/bands.
  defp tools_opts do
    [
      scopes: ["public"],
      prototypes: [%{intent: :recall, tier: :tier_tools, text: "T"}],
      embedder: fn _ -> {:ok, [1.0, 0.0, 0.0]} end,
      bands: %Bands{handle: 0.5}
    ]
  end

  defp escalate_opts(generator) do
    [
      scopes: ["public"],
      prototypes: [%{intent: :recall, tier: :tier_tools, text: "T"}],
      # proto "T" → axis 0; everything else → axis 2 → cosine 0 → escalate
      embedder: fn
        "T" -> {:ok, [1.0, 0.0, 0.0]}
        _ -> {:ok, [0.0, 0.0, 1.0]}
      end,
      bands: %Bands{handle: 0.5},
      fleet: %{panel: ["m1"], judge: "j"},
      generator: generator
    ]
  end

  test "status reports graph size" do
    ingest_public_files()
    assert Core.status().nodes >= 2
  end

  test "search is scope-filtered (default-deny)" do
    ingest_public_files()

    hits = Core.search("storage", ["public"], limit: 10)
    assert Enum.any?(hits, &(&1.key =~ "storage"))

    assert Core.search("storage", ["private"], []) == []
    assert Core.search("storage", [], []) == []
  end

  test "ask routes tier-tools to a cited retrieval answer" do
    ingest_public_files()
    a = Core.ask("storage engine details", tools_opts())

    assert a.tier == "tier_tools"
    assert Enum.any?(a.citations, &(&1.ref =~ "storage"))
  end

  test "ask escalates to the consilium and returns a synthesized cited answer" do
    ingest_public_files()

    generator = fn _model, _prompt, opts ->
      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer": "synthesized verdict", "confidence": 0.8})},
        else: {:ok, "panel take"}
    end

    a = Core.ask("storage engine details", escalate_opts(generator))
    assert a.tier == "escalate"
    assert a.answer == "synthesized verdict"
    assert a.confidence == 0.8
  end

  test "ask stays fail-loud when the judge fails (low confidence, no raw text)" do
    ingest_public_files()

    generator = fn _model, _prompt, opts ->
      if Keyword.get(opts, :json), do: {:ok, "not json"}, else: {:ok, "panel take"}
    end

    a = Core.ask("storage engine details", escalate_opts(generator))
    assert a.tier == "escalate"
    assert a.confidence == 0.0
    assert a.citations == []
  end
end
