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
        do: {:ok, ~s({"answer":"synthesized","confidence":0.8})},
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
end
