defmodule Swarm.CoreTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Core
  alias Swarm.Gate.Bands
  alias Swarm.Graph.Store

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
        do: {:ok, ~s({"answer": "synthesized verdict", "confidence": 0.8, "supported": true})},
        else: {:ok, "panel take"}
    end

    a = Core.ask("storage engine details", escalate_opts(generator))
    assert a.tier == "escalate"
    assert a.answer == "synthesized verdict"
    # confidence is calibrated (judge × agreement × retrieval cap); the real retriever
    # supplies the relevance signal, so assert it stays a sane, non-crushed number.
    assert a.confidence > 0.0 and a.confidence <= 0.8
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

  describe "ADR-17 tier-routing gate (Fork B) wire" do
    defp seed_procedure do
      p = Store.upsert_node("entity", "ldap password reset", scope: "public")
      s1 = Store.upsert_node("concept", "open the self-service portal", scope: "public")
      s2 = Store.upsert_node("concept", "choose a new password", scope: "public")

      for {s, ord} <- [{s1, 1}, {s2, 2}] do
        {:ok, _} =
          Store.add_edge(p, s, "has_step", "wiki:reset",
            scope: "public",
            origin: "wiki:reset",
            evidence_kind: "claim",
            step_ordinal: ord,
            source_node_id: p
          )
      end

      p
    end

    # A retriever that surfaces the procedure entity so its key becomes a gate candidate.
    defp proc_retriever(p) do
      fn _q, _s, _o ->
        {:ok, [%{id: p, type: "entity", key: "ldap password reset", score: 0.9}]}
      end
    end

    defp consilium_stub do
      fn _model, _prompt, opts ->
        if Keyword.get(opts, :json),
          do: {:ok, ~s({"answer": "consilium answer", "confidence": 0.8, "supported": true})},
          else: {:ok, "panel take"}
      end
    end

    defp seed_entity_profile do
      service = Store.upsert_node("entity", "atlas search", scope: "public")
      kind = Store.upsert_node("concept", "document indexing service", scope: "public")

      {:ok, _} =
        Store.add_edge(service, kind, "is_a", "wiki:atlas",
          scope: "public",
          origin: "wiki:atlas",
          evidence_kind: "claim",
          source_node_id: service
        )

      service
    end

    test "serves a clean procedure from structure (tier=structured, consilium bypassed)" do
      p = seed_procedure()

      opts =
        escalate_opts(consilium_stub()) ++
          [retriever: proc_retriever(p), tier_gate: true, entail_fun: fn _q, _g -> true end]

      a = Core.ask("how to reset the ldap password", opts)

      assert a.tier == "structured"
      assert a.status == :found
      assert a.answer =~ "open the self-service portal"
      assert a.answer =~ "choose a new password"
      # opaque citation only — never the raw origin
      assert Enum.all?(a.citations, &(&1.source == "structured"))
      refute a.answer =~ "wiki"
      # chat-thread epic 2: the served entity's real key rides along in citations (not
      # just the gate's opaque "corroboration:N" labels) — a channel echoing THESE refs
      # back as the next turn's active_keys must be able to re-hit this same procedure.
      assert "ldap password reset" in Enum.map(a.citations, & &1.ref)
    end

    test "chat-thread epic 2: a structured turn's own citations re-serve the NEXT pronoun follow-up" do
      p = seed_procedure()

      opts1 =
        escalate_opts(consilium_stub()) ++
          [retriever: proc_retriever(p), tier_gate: true, entail_fun: fn _q, _g -> true end]

      first = Core.ask("how to reset the ldap password", opts1)
      assert first.tier == "structured"
      echoed_keys = Enum.map(first.citations, & &1.ref)

      opts2 =
        escalate_opts(consilium_stub()) ++
          [
            retriever: unrelated_retriever(),
            tier_gate: true,
            entail_fun: fn _q, _g -> true end,
            active_keys: echoed_keys
          ]

      second = Core.ask("and how do I do that again?", opts2)
      assert second.tier == "structured"
      assert second.answer =~ "open the self-service portal"
    end

    test "entailment NO vetoes the serve ⇒ escalates to the consilium (near-miss guard)" do
      p = seed_procedure()

      opts =
        escalate_opts(consilium_stub()) ++
          [retriever: proc_retriever(p), tier_gate: true, entail_fun: fn _q, _g -> false end]

      a = Core.ask("how to reset the ldap password", opts)
      assert a.tier == "escalate"
      assert a.answer == "consilium answer"
    end

    test "gate OFF by default ⇒ escalates even when structure exists (behaviour-neutral wire)" do
      p = seed_procedure()
      opts = escalate_opts(consilium_stub()) ++ [retriever: proc_retriever(p)]

      a = Core.ask("how to reset the ldap password", opts)
      assert a.tier == "escalate"
      assert a.answer == "consilium answer"
    end

    test "entity_profile serve requires explicit entity_serve opt-in" do
      _service = seed_entity_profile()
      opts = escalate_opts(consilium_stub()) ++ [retriever: fn _q, _s, _o -> {:ok, []} end]

      off = Core.ask("what is atlas search", opts ++ [tier_gate: true])
      assert off.tier == "escalate"

      on =
        Core.ask(
          "what is atlas search",
          opts ++ [tier_gate: true, entity_serve: true, entail_fun: fn _q, _g -> true end]
        )

      assert on.tier == "structured"
      assert on.answer =~ "is a"
      assert on.answer =~ "document indexing service"
    end

    # An UNRELATED retriever — hit_keys/Procedure.candidates alone give the gate no
    # matching candidate — simulates a context-free pronoun follow-up ("and how do I
    # do that again?") whose OWN text carries no usable key.
    defp unrelated_retriever do
      fn _q, _s, _o -> {:ok, [%{id: 999, type: "entity", key: "unrelated thing", score: 0.1}]} end
    end

    test "chat-thread epic 2: without active_keys, a pronoun follow-up finds nothing to serve" do
      _p = seed_procedure()

      opts =
        escalate_opts(consilium_stub()) ++
          [retriever: unrelated_retriever(), tier_gate: true, entail_fun: fn _q, _g -> true end]

      a = Core.ask("and how do I do that again?", opts)
      assert a.tier == "escalate"
    end

    test "chat-thread epic 2: active_keys let the SAME pronoun follow-up hit the structured gate" do
      _p = seed_procedure()

      opts =
        escalate_opts(consilium_stub()) ++
          [
            retriever: unrelated_retriever(),
            tier_gate: true,
            entail_fun: fn _q, _g -> true end,
            active_keys: ["ldap password reset"]
          ]

      a = Core.ask("and how do I do that again?", opts)
      assert a.tier == "structured"
      assert a.status == :found
      assert a.answer =~ "open the self-service portal"
    end

    test "chat-thread epic 2: active_keys are sanitized (blanks dropped, never crash)" do
      _p = seed_procedure()

      opts =
        escalate_opts(consilium_stub()) ++
          [
            retriever: unrelated_retriever(),
            tier_gate: true,
            entail_fun: fn _q, _g -> true end,
            active_keys: ["", nil, "ldap password reset", ""]
          ]

      a = Core.ask("and how do I do that again?", opts)
      assert a.tier == "structured"
    end
  end
end
