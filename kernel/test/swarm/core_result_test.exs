defmodule Swarm.CoreResultTest do
  @moduledoc """
  T6 — the answer-result algebra. A lookup that resolves to nothing, a transport
  failure, and a partial-source result must be DISTINCT typed outcomes — never a
  not-found masquerading as an outage, never a raw error leaked, never a partial
  silently presented as complete, never a raised exception in the turn.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Core
  alias Swarm.Gate.Bands
  alias Swarm.Graph.Store
  alias Swarm.Ingest.Content

  # Force tier_tools (the gate is injected) + an optional retriever override.
  defp tools_opts(extra \\ []) do
    [
      scopes: ["public"],
      prototypes: [%{intent: :recall, tier: :tier_tools, text: "T"}],
      embedder: fn _ -> {:ok, [1.0, 0.0, 0.0]} end,
      bands: %Bands{handle: 0.5}
    ] ++ extra
  end

  defp ingest_public_file(key) do
    {:ok, :written} =
      Swarm.Ingest.ingest(%{
        provenance: key,
        occurred_at: DateTime.utc_now(),
        entities: [%{type: "file", key: key, scope: "public", content: "f"}],
        relations: []
      })
  end

  test "a nonexistent lookup → structured :not_found, turn survives (real retriever)" do
    a = Core.ask("zzznonexistentzzz", tools_opts())

    assert a.status == :not_found
    assert a.tier == "tier_tools"
    assert a.citations == []
    assert is_binary(a.answer)
  end

  test "a real hit → :found with citations" do
    ingest_public_file("/docs/storage_engine.md")
    a = Core.ask("storage", tools_opts())

    assert a.status == :found
    assert a.citations != []
  end

  test "content citations include configured source URL when source_ref is linkable" do
    original = Application.get_env(:swarm, :citation_url_templates)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:swarm, :citation_url_templates),
        else: Application.put_env(:swarm, :citation_url_templates, original)
    end)

    Application.put_env(:swarm, :citation_url_templates, %{
      "confluence" => "https://docs.example.test/pages/{id}"
    })

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "article",
           key: "Example.test AI Solution",
           score: 0.9,
           source_ref: "confluence:12345"
         }
       ]}
    end

    a = Core.ask("where is this written?", tools_opts(retriever: retr))

    assert [%{source: "article", ref: "Example.test AI Solution", url: url}] = a.citations
    assert url == "https://docs.example.test/pages/12345"
  end

  test "content citations stay plaintext when no template exists" do
    original = Application.get_env(:swarm, :citation_url_templates)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:swarm, :citation_url_templates),
        else: Application.put_env(:swarm, :citation_url_templates, original)
    end)

    Application.delete_env(:swarm, :citation_url_templates)

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "article",
           key: "Example.test AI Solution",
           score: 0.9,
           source_ref: "confluence:12345"
         }
       ]}
    end

    a = Core.ask("where is this written?", tools_opts(retriever: retr))

    assert [%{source: "article", ref: "Example.test AI Solution"} = citation] = a.citations
    refute Map.has_key?(citation, :url)
  end

  test "content citations stay plaintext when source ref or template is malformed" do
    original = Application.get_env(:swarm, :citation_url_templates)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:swarm, :citation_url_templates),
        else: Application.put_env(:swarm, :citation_url_templates, original)
    end)

    Application.put_env(:swarm, :citation_url_templates, %{
      "confluence" => "not-a-url/{id}",
      "mediawiki" => "javascript:{id}",
      "valid" => "https://docs.example.test/pages/{id}"
    })

    for source_ref <- ["confluence:12345", "mediawiki:12345", "valid:"] do
      retr = fn _q, _s, _o ->
        {:ok,
         [
           %{
             id: 1,
             type: "article",
             key: "Example.test AI Solution",
             score: 0.9,
             source_ref: source_ref
           }
         ]}
      end

      a = Core.ask("where is this written?", tools_opts(retriever: retr))

      assert [%{source: "article", ref: "Example.test AI Solution"} = citation] = a.citations
      refute Map.has_key?(citation, :url)
    end
  end

  test "source-link follow-up uses visible active citation keys" do
    original = Application.get_env(:swarm, :citation_url_templates)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:swarm, :citation_url_templates),
        else: Application.put_env(:swarm, :citation_url_templates, original)
    end)

    Application.put_env(:swarm, :citation_url_templates, %{
      "confluence" => "https://docs.example.test/pages/{id}"
    })

    id = Store.upsert_node("article", "Example.test AI Solution", scope: "public")
    :ok = Content.put_body(id, "AI Solution source body.", source_ref: "confluence:12345")

    a =
      Core.ask(
        "Could you share the wiki page link?",
        tools_opts(active_keys: ["Example.test AI Solution"])
      )

    assert a.status == :found
    assert a.tier == "tier_tools"
    assert a.answer == "https://docs.example.test/pages/12345"
    assert [%{source: "article", ref: "Example.test AI Solution", url: url}] = a.citations
    assert url == "https://docs.example.test/pages/12345"
  end

  test "a transport failure → :error, DISTINCT from not_found, no raw leak, not silent" do
    a =
      Core.ask(
        "storage",
        tools_opts(retriever: fn _q, _s, _o -> {:error, {:retrieval_failed, "boom"}} end)
      )

    assert a.status == :error
    assert a.status != :not_found
    assert a.confidence == 0.0
    # the raw error detail is logged, never shown to the user
    refute a.answer =~ "boom"
  end

  test "a partial-source result is typed :partial, not silently complete" do
    hits = [%{id: 1, type: "file", key: "/docs/a.md", score: 1.0}]

    a =
      Core.ask(
        "storage",
        tools_opts(retriever: fn _q, _s, _o -> {:partial, hits, [:source_b]} end)
      )

    assert a.status == :partial
    assert length(a.citations) == 1
    assert a.answer =~ "Partial"
  end

  test "not_found and error are genuinely different outcomes for the same query" do
    nf = Core.ask("zzzmissing", tools_opts(retriever: fn _q, _s, _o -> {:ok, []} end))
    er = Core.ask("zzzmissing", tools_opts(retriever: fn _q, _s, _o -> {:error, :down} end))

    assert nf.status == :not_found
    assert er.status == :error
    assert nf.answer != er.answer
  end

  # Force escalate (proto "T" → axis 0; everything else → axis 2 → cosine 0).
  defp escalate_opts(generator, extra \\ []) do
    [
      scopes: ["public"],
      prototypes: [%{intent: :recall, tier: :tier_tools, text: "T"}],
      embedder: fn
        "T" -> {:ok, [1.0, 0.0, 0.0]}
        _ -> {:ok, [0.0, 0.0, 1.0]}
      end,
      bands: %Bands{handle: 0.5},
      fleet: %{panel: ["m1"], judge: "j"},
      generator: generator
    ] ++ extra
  end

  test "escalate with a successful synthesis → :found" do
    gen = fn _model, _prompt, opts ->
      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"synthesized","confidence":0.8,"supported":true})},
        else: {:ok, "panel take"}
    end

    a = Core.ask("explain storage", escalate_opts(gen))
    assert a.tier == "escalate"
    assert a.status == :found
  end

  test "escalate with a failed synthesis → :error (distinct, no raw panel text)" do
    # judge always returns invalid JSON → judge fails → synthesis error
    gen = fn _model, _prompt, opts ->
      if Keyword.get(opts, :json), do: {:ok, "not json"}, else: {:ok, "panel take"}
    end

    a = Core.ask("explain storage", escalate_opts(gen))
    assert a.tier == "escalate"
    assert a.status == :error
    assert a.confidence == 0.0
    refute a.answer =~ "panel take"
  end

  test "a programmer bug in retrieval crashes loudly, not mislabeled an outage" do
    # an injected retriever that RAISES is not swallowed (the narrow-rescue rule);
    # only genuine transport errors become :error.
    assert_raise RuntimeError, fn ->
      Core.ask("storage", tools_opts(retriever: fn _q, _s, _o -> raise "kernel bug" end))
    end
  end

  # ADR-15: an escalation WITH a viewer retains its deliberation, surfaced as an
  # opaque ask_ref on the answer; an anonymous escalation retains nothing.
  defp ok_gen do
    fn _model, _prompt, opts ->
      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"synthesized","confidence":0.8,"supported":true})},
        else: {:ok, "panel take"}
    end
  end

  test "escalate with a viewer retains a deliberation (opaque ask_ref, re-openable)" do
    a = Core.ask("explain storage", escalate_opts(ok_gen(), viewer: "alice"))

    assert a.tier == "escalate"
    ask_ref = Map.get(a, :ask_ref, "")
    assert ask_ref != ""
    assert {:ok, d} = Swarm.Deliberation.fetch(ask_ref, "alice", ["public"])
    assert d.judge == "j"
    assert d.panel == [%{model: "m1", answer: "panel take"}]
  end

  test "escalate without a viewer retains nothing (ask_ref empty)" do
    a = Core.ask("explain storage", escalate_opts(ok_gen()))

    assert a.tier == "escalate"
    assert Map.get(a, :ask_ref, "") == ""
  end

  # C1 (chunk-grounding): the consilium must be fed the answer-bearing PASSAGE of a
  # content hit (its spans), not just "- type: key" titles (the starved-not-dumb bug).
  test "escalate grounds the consilium on the matched passage, not the bare title" do
    test_pid = self()

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "article",
           key: "Public IP",
           score: 0.72,
           relevance: 0.72,
           spans: [%{ordinal: 3, text: "## Networking\nNebula public IP is 203.0.113.7."}]
         }
       ]}
    end

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"203.0.113.7","confidence":0.8,"supported":true})},
        else: {:ok, "203.0.113.7"}
    end

    a = Core.ask("what is the nebula public ip", escalate_opts(gen, retriever: retr))
    assert a.tier == "escalate"

    # the value-bearing passage reached the model (not just the title line)
    assert_received {:grounding_prompt, prompt}
    assert prompt =~ "203.0.113.7"
    assert prompt =~ "Public IP"
  end

  test "escalation grounding orders admitted hits by relevance before applying the budget" do
    test_pid = self()
    filler = String.duplicate("broad context that mentions nebula but not the address\n", 220)

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "article",
           key: "Nebula overview",
           score: 0.5,
           relevance: 0.5,
           spans: [%{ordinal: 1, text: filler}]
         },
         %{
           id: 2,
           type: "article",
           key: "Public IP",
           score: 0.9,
           relevance: 0.9,
           spans: [%{ordinal: 1, text: "Nebula public IP is 203.0.113.7."}]
         }
       ]}
    end

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"203.0.113.7","confidence":0.8,"supported":true})},
        else: {:ok, "203.0.113.7"}
    end

    a = Core.ask("what is the nebula public ip", escalate_opts(gen, retriever: retr))
    assert a.tier == "escalate"

    assert_received {:grounding_prompt, prompt}
    assert prompt =~ "Nebula public IP is 203.0.113.7."

    assert :binary.match(prompt, "## article: Public IP") <
             :binary.match(prompt, "## article: Nebula overview")
  end

  test "escalate follow-ups ground active citation keys as scoped passages" do
    test_pid = self()
    id = Store.upsert_node("article", "Runner Guidance", scope: "public")

    :ok =
      Content.put_body(
        id,
        "Runner guidance body: Alpha Runner should be avoided; Beta Runner is recommended.",
        source_ref: "mediawiki:123"
      )

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"Beta Runner is recommended.","confidence":0.8,"supported":true})},
        else: {:ok, "panel take"}
    end

    a = Core.ask("why avoid Alpha?", escalate_opts(gen, active_keys: ["Runner Guidance"]))

    assert a.tier == "escalate"
    assert_received {:grounding_prompt, prompt}
    assert prompt =~ "Runner guidance body"
  end

  # A title/identity key hit (no spans) still contributes its identity line — never
  # a fabricated passage — so identity/inventory grounding keeps working.
  test "escalate grounding falls back to the identity line for a span-less hit" do
    test_pid = self()
    retr = fn _q, _s, _o -> {:ok, [%{id: 7, type: "ticket", key: "TCK-7", score: 1.0}]} end

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"x","confidence":0.5,"supported":true})},
        else: {:ok, "x"}
    end

    Core.ask("show ticket details", escalate_opts(gen, retriever: retr))
    assert_received {:grounding_prompt, prompt}
    assert prompt =~ "ticket: TCK-7"
  end

  test "escalate restricts grounding to an exact named-title hit before min-hit gating" do
    test_pid = self()

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "page",
           key: "Example.test AI Solution",
           score: 0.79,
           relevance: 0.79,
           spans: [%{ordinal: 1, text: "Example.test AI Solution provides agent services."}]
         },
         %{
           id: 2,
           type: "page",
           key: "Example.test Agentic AI",
           score: 0.59,
           relevance: 0.59,
           spans: [%{ordinal: 1, text: "Agentic AI gives adjacent architecture context."}]
         },
         %{
           id: 3,
           type: "page",
           key: "Install Example.test Certificate",
           score: 0.58,
           relevance: 0.58,
           spans: [%{ordinal: 1, text: "Certificate authority material."}]
         },
         %{
           id: 4,
           type: "page",
           key: "Example.test DevOps",
           score: 0.0,
           relevance: 0.0,
           spans: [%{ordinal: 1, text: "Helpdesk, Docker and Podman installation notes."}]
         }
       ]}
    end

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do:
          {:ok,
           ~s({"answer":"Example.test AI Solution summary","confidence":0.8,"supported":true})},
        else: {:ok, "Example.test AI Solution summary"}
    end

    a = Core.ask("розкажи про Example.test AI Solution", escalate_opts(gen, retriever: retr))
    assert a.status == :found

    assert_received {:grounding_prompt, prompt}
    assert prompt =~ "Example.test AI Solution"
    refute prompt =~ "Agentic AI"
    refute prompt =~ "Certificate authority"
    refute prompt =~ "Helpdesk"
    refute prompt =~ "Docker"
    refute prompt =~ "Podman"
    assert Enum.map(a.citations, & &1.ref) == ["Example.test AI Solution"]
  end

  test "escalate gates broad query-term claim facts when passage grounding is present" do
    s = add_node!(%{type: "entity", key: "ee.helpdesk@smile.fr", scope: "public"})
    o = add_node!(%{type: "entity", key: "ee helpdesk", scope: "public"})
    {:ok, _} = Graph.add_edge(s, o, "part_of", "p1", evidence_kind: "claim", scope: "public")

    s2 = add_node!(%{type: "entity", key: "Experts at Smile", scope: "public"})
    o2 = add_node!(%{type: "entity", key: "training paths", scope: "public"})

    {:ok, _} =
      Graph.add_edge(s2, o2, "created_by", "p1", evidence_kind: "claim", scope: "public")

    test_pid = self()

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "page",
           key: "AI Solution at Smile",
           score: 0.79,
           relevance: 0.79,
           spans: [%{ordinal: 1, text: "AI Solution at Smile provides agent services."}]
         }
       ]}
    end

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"AI Solution summary","confidence":0.8,"supported":true})},
        else: {:ok, "AI Solution summary"}
    end

    a = Core.ask("розкажи про AI Solution at Smile", escalate_opts(gen, retriever: retr))

    assert_received {:grounding_prompt, prompt}
    refute prompt =~ "ee.helpdesk"
    refute prompt =~ "ee helpdesk"
    refute prompt =~ "Experts at Smile"
    refute prompt =~ "training paths"
    refute Enum.any?(a.citations, &(&1.source == "claim" and &1.ref =~ "ee.helpdesk"))
    refute Enum.any?(a.citations, &(&1.source == "claim" and &1.ref =~ "Experts at Smile"))
  end

  test "escalate keeps a minimum grounding set when all relevance is weak" do
    test_pid = self()

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{id: 1, type: "page", key: "A", score: 0.1, relevance: 0.1, spans: [%{text: "A"}]},
         %{id: 2, type: "page", key: "B", score: 0.02, relevance: 0.02, spans: [%{text: "B"}]},
         %{id: 3, type: "page", key: "C", score: 0.01, relevance: 0.01, spans: [%{text: "C"}]},
         %{id: 4, type: "page", key: "D", score: 0.0, relevance: 0.0, spans: [%{text: "D"}]}
       ]}
    end

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"broad summary","confidence":0.8,"supported":true})},
        else: {:ok, "broad summary"}
    end

    Core.ask("broad summary", escalate_opts(gen, retriever: retr))

    assert_received {:grounding_prompt, prompt}
    assert prompt =~ "page: A"
    assert prompt =~ "page: B"
    assert prompt =~ "page: C"
    refute prompt =~ "page: D"
  end

  test "broad example.test ask without exact title still keeps the minimum grounding set" do
    test_pid = self()

    retr = fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "page",
           key: "Example.test Policy",
           score: 0.1,
           relevance: 0.1,
           spans: [%{text: "Example.test policy overview"}]
         },
         %{
           id: 2,
           type: "page",
           key: "Example.test Procedure",
           score: 0.02,
           relevance: 0.02,
           spans: [%{text: "Example.test procedure overview"}]
         },
         %{
           id: 3,
           type: "page",
           key: "Example.test Reference",
           score: 0.01,
           relevance: 0.01,
           spans: [%{text: "Example.test reference overview"}]
         },
         %{
           id: 4,
           type: "page",
           key: "Example.test Incident",
           score: 0.0,
           relevance: 0.0,
           spans: [%{text: "Example.test incident overview"}]
         }
       ]}
    end

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"broad example.test summary","confidence":0.8,"supported":true})},
        else: {:ok, "broad example.test summary"}
    end

    Core.ask("tell me about Example.test", escalate_opts(gen, retriever: retr))

    assert_received {:grounding_prompt, prompt}
    assert prompt =~ "page: Example.test Policy"
    assert prompt =~ "page: Example.test Procedure"
    assert prompt =~ "page: Example.test Reference"
    refute prompt =~ "page: Example.test Incident"
  end

  # C2 (confidence calibration, the lynchpin): a judge that ABSTAINS (supported=false)
  # must yield a LOW-confidence :not_found, never a high-confidence answer — even when
  # the judge self-reports 0.9. Fail-closed: a missing `supported` is treated as false.
  defp judge_gen(json) do
    fn _model, _prompt, opts ->
      if Keyword.get(opts, :json), do: {:ok, json}, else: {:ok, "panel take"}
    end
  end

  defp hit_with_relevance(r) do
    fn _q, _s, _o ->
      {:ok,
       [
         %{
           id: 1,
           type: "article",
           key: "Public IP",
           score: r,
           relevance: r,
           spans: [%{ordinal: 1, text: "Nebula public IP is 203.0.113.7."}]
         }
       ]}
    end
  end

  test "an ungrounded answer (supported=false) ⇒ :not_found, confidence 0.0, no citations" do
    gen =
      judge_gen(
        ~s({"answer":"That detail is not in the provided text.","confidence":0.9,"supported":false})
      )

    a =
      Core.ask(
        "what is the nebula public ip",
        escalate_opts(gen, retriever: hit_with_relevance(0.7))
      )

    assert a.status == :not_found
    assert a.confidence == 0.0
    assert a.citations == []
    refute a.answer =~ "not in the provided text"
  end

  test "a missing supported flag fails CLOSED (treated as not grounded)" do
    gen = judge_gen(~s({"answer":"203.0.113.7","confidence":0.9}))

    a =
      Core.ask(
        "what is the nebula public ip",
        escalate_opts(gen, retriever: hit_with_relevance(0.7))
      )

    assert a.status == :not_found
    assert a.confidence == 0.0
  end

  test "a grounded answer with strong retrieval is NOT crushed (≈ judge × agreement)" do
    gen = judge_gen(~s({"answer":"203.0.113.7","confidence":0.9,"supported":true}))

    a =
      Core.ask(
        "what is the nebula public ip",
        escalate_opts(gen, retriever: hit_with_relevance(0.6))
      )

    assert a.status == :found
    # single-model panel ⇒ disagreement 0 ⇒ agreement 1; relevance 0.6 ≥ target ⇒ cap 1.0
    assert_in_delta a.confidence, 0.9, 1.0e-6
  end

  test "a grounded answer on MARGINAL retrieval is capped lower (honest), not zeroed" do
    gen = judge_gen(~s({"answer":"203.0.113.7","confidence":0.9,"supported":true}))

    a =
      Core.ask(
        "what is the nebula public ip",
        escalate_opts(gen, retriever: hit_with_relevance(0.45))
      )

    assert a.status == :found
    # relevance at the floor ⇒ cap 0.6 ⇒ 0.9 × 0.6 = 0.54 (capped, not crushed to 0)
    assert_in_delta a.confidence, 0.54, 1.0e-6
  end

  # C3 (claim-aware): a claim-graph fact about the query's entity is surfaced into
  # the consilium grounding directly (not only if a chunk lands).
  test "escalate folds a scope-visible claim fact into the grouped grounding (STEP 2)" do
    s = add_node!(%{type: "entity", key: "Nebula", scope: "public"})
    o = add_node!(%{type: "entity", key: "203.0.113.7", scope: "public"})
    {:ok, _} = Graph.add_edge(s, o, "public_ip", "p1", evidence_kind: "claim", scope: "public")

    test_pid = self()

    gen = fn _model, prompt, opts ->
      send(test_pid, {:grounding_prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer":"203.0.113.7","confidence":0.8,"supported":true})},
        else: {:ok, "203.0.113.7"}
    end

    # real retriever (no override) → no ingested content; the aggregation path supplies the fact
    a = Core.ask("what is the nebula public ip", escalate_opts(gen))
    assert_received {:grounding_prompt, prompt}
    # grouped profile grounding: entity heading + the value under the canonical predicate
    assert prompt =~ "## Nebula"
    assert prompt =~ "203.0.113.7"

    # a claim-only :found answer (no retrieval hits) is still CITED — explainable —
    # and NOT crushed to 0 (claim_support feeds the calibration cap, gemini's #1 fix).
    assert a.status == :found
    assert a.confidence > 0.0
    assert Enum.any?(a.citations, &(&1.source == "claim" and &1.ref =~ "Nebula public ip"))
  end
end
