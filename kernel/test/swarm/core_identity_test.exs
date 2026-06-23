defmodule Swarm.CoreIdentityTest do
  @moduledoc """
  T8 — the kernel self-model (P6) and asker identity (P11). The self-model reports
  real ingest state (never "I have no KB" while docs sit indexed); "my X" resolves
  to the asker and is scoped, while an anonymous first-person request is limited.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Core
  alias Swarm.Gate.Bands

  defp tools_opts(extra \\ []) do
    [
      scopes: ["public"],
      prototypes: [%{intent: :recall, tier: :tier_tools, text: "T"}],
      embedder: fn _ -> {:ok, [1.0, 0.0, 0.0]} end,
      bands: %Bands{handle: 0.5}
    ] ++ extra
  end

  defp ingest(type, key) do
    {:ok, :written} =
      Swarm.Ingest.ingest(%{
        provenance: key,
        occurred_at: DateTime.utc_now(),
        entities: [%{type: type, key: key, scope: "public", content: "x"}],
        relations: []
      })
  end

  describe "self-model (P6) — from real state, not a guess" do
    test "reflects per-type inventory, freshness, and live capabilities" do
      ingest("file", "/docs/a.md")
      ingest("file", "/docs/b.md")
      ingest("concept", "topic-x")

      s = Core.status()

      assert s.nodes >= 3
      assert Enum.any?(s.inventory, &(&1.type == "file" and &1.count >= 2))
      assert Enum.any?(s.inventory, &(&1.type == "concept"))
      # freshness: a real last-activity timestamp, not blank
      assert s.last_activity != ""
      # live capability: the consilium panel is reported from config
      assert Enum.any?(s.capabilities, &String.contains?(&1, "consilium"))
    end
  end

  describe "asker identity (P11)" do
    test "'my X' with a viewer resolves to that viewer's items, scoped" do
      ingest("ticket", "alice-ticket-1")
      ingest("ticket", "bob-ticket-2")

      a = Core.ask("my ticket", tools_opts(viewer: "alice"))

      refs = Enum.map(a.citations, & &1.ref)
      assert "alice-ticket-1" in refs
      refute "bob-ticket-2" in refs
    end

    test "'my X' without a viewer is LIMITED (identity required), not a broad dump" do
      ingest("ticket", "alice-ticket-1")

      a = Core.ask("my ticket", tools_opts())

      assert a.status == :not_found
      assert a.citations == []
      assert a.answer =~ "identify"
    end

    test "a non-first-person query ignores the viewer (no owner narrowing)" do
      ingest("ticket", "alice-ticket-1")
      ingest("ticket", "bob-ticket-2")

      a = Core.ask("ticket", tools_opts(viewer: "alice"))

      refs = Enum.map(a.citations, & &1.ref)
      assert "alice-ticket-1" in refs
      assert "bob-ticket-2" in refs
    end

    test "bare 'me' is NOT an ownership query (no false identity_required)" do
      ingest("concept", "postgres-notes")

      # "tell me about postgres" must answer normally, not demand identity
      a = Core.ask("tell me about postgres", tools_opts())

      refute a.status == :not_found
      assert a.tier == "tier_tools"
    end

    test "a short viewer id does NOT substring-match another asker (anchored)" do
      ingest("ticket", "alice-ticket-1")

      # viewer "al" must not be mis-attributed alice's items
      a = Core.ask("my ticket", tools_opts(viewer: "al"))

      assert a.citations == []
      assert a.status == :not_found
    end
  end
end
