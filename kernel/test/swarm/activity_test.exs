defmodule Swarm.ActivityTest do
  @moduledoc """
  ADR-15 — the polled, scope-safe ActivityFeed over the `outbox` thin slice.
  Asserts the no-leak gate: out-of-scope subjects are absent (not redacted), the
  cursor is opaque so gaps are not inferable, `count` is in-scope-only, the page
  is bounded/clamped, kinds filter, and default-deny. Rich ER/enrichment outcomes
  are loop-gated (assert-skipped).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Activity
  alias Swarm.Activity.Cursor

  test "thin slice present now: an outbox node write is one scope-safe typed event" do
    add_node!(%{type: "article", scope: "public"})

    page = Activity.feed(scopes: ["public"])

    assert page.status == :found
    assert [ev] = page.events
    assert ev.kind == "node_added"
    assert ev.subject_type == "article"
    assert ev.outcome == ""
    assert ev.count == 0
    # No raw payload/target_key/key/seq ever reaches the wire — only the typed fields.
    assert Enum.sort(Map.keys(ev)) == [:at, :count, :kind, :outcome, :subject_type]
  end

  test "no-leak: an event on an out-of-scope node is ABSENT for that viewer (not redacted)" do
    add_node!(%{type: "article", scope: "public"})
    add_node!(%{type: "file", scope: "private"})

    page = Activity.feed(scopes: ["public"])

    assert Enum.map(page.events, & &1.subject_type) == ["article"]
    refute Enum.any?(page.events, &(&1.subject_type == "file"))
  end

  test "opaque cursor: hidden middle event is skipped AND the gap is not inferable" do
    add_node!(%{type: "article", scope: "public"})
    add_node!(%{type: "file", scope: "private"})
    add_node!(%{type: "concept", scope: "public"})

    page = Activity.feed(scopes: ["public"])

    # Oldest→newest, the private middle event silently absent.
    assert Enum.map(page.events, & &1.subject_type) == ["article", "concept"]
    # The cursor reveals no raw seq — opaque, decodes only with the kernel key.
    refute page.next_cursor == "3"
    assert {:ok, _seq} = Cursor.decode(page.next_cursor)
    # Polling forward from the tail yields nothing — the hidden event never surfaces
    # and the client cannot tell one was skipped.
    nxt = Activity.feed(scopes: ["public"], cursor: page.next_cursor)
    assert nxt.status == :not_found
    assert nxt.events == []
  end

  test "no poll-count leak: cadence tracks VISIBLE volume, not hidden volume" do
    # 5 public events interleaved among 20 private (25 outbox writes). A public
    # viewer paging at limit 2 must reach all 5 in ceil(5/2)=3 polls — independent
    # of how many hidden rows sit between them (the side channel codex flagged).
    for i <- 1..25 do
      add_node!(%{type: "article", scope: if(rem(i, 5) == 0, do: "public", else: "private")})
    end

    consume = fn consume, cursor, polls, seen ->
      page = Activity.feed(scopes: ["public"], cursor: cursor, limit: 2)

      if page.events == [],
        do: {polls, seen},
        else: consume.(consume, page.next_cursor, polls + 1, seen + length(page.events))
    end

    {polls, seen} = consume.(consume, Cursor.encode(0), 0, 0)
    assert seen == 5
    assert polls == 3
  end

  test "follow-forward: a resume cursor returns only newer events, then tails out" do
    add_node!(%{type: "article", scope: "public"})
    add_node!(%{type: "article", scope: "public"})

    p1 = Activity.feed(scopes: ["public"])
    assert length(p1.events) == 2

    add_node!(%{type: "concept", scope: "public"})

    p2 = Activity.feed(scopes: ["public"], cursor: p1.next_cursor)
    assert p2.status == :found
    assert [ev] = p2.events
    assert ev.subject_type == "concept"

    p3 = Activity.feed(scopes: ["public"], cursor: p2.next_cursor)
    assert p3.status == :not_found
    assert p3.events == []
  end

  test "\"\" ⇒ most recent, clamped to limit (newest, oldest→newest within the page)" do
    add_node!(%{type: "article", scope: "public"})
    add_node!(%{type: "file", scope: "public"})
    add_node!(%{type: "concept", scope: "public"})

    page = Activity.feed(scopes: ["public"], limit: 2)
    assert Enum.map(page.events, & &1.subject_type) == ["file", "concept"]

    assert length(Activity.feed(scopes: ["public"], limit: 0).events) == 3
    assert length(Activity.feed(scopes: ["public"], limit: 9999).events) == 3
  end

  test "kinds filters to the requested closed-set event kinds" do
    a = add_node!(%{type: "article", scope: "public"})
    b = add_node!(%{type: "concept", scope: "public"})
    {:ok, _} = Graph.add_edge(a, b, "mentions", "p1", reliability: 0.9, scope: "public")

    page = Activity.feed(scopes: ["public"], kinds: ["edge_reinforced"])

    assert [ev] = page.events
    assert ev.kind == "edge_reinforced"
    assert ev.subject_type == ""
  end

  test "an edge's OWN visibility_scope gates its event (private edge dropped)" do
    a = add_node!(%{type: "article", scope: "public"})
    b = add_node!(%{type: "concept", scope: "public"})
    {:ok, _} = Graph.add_edge(a, b, "mentions", "p1", reliability: 0.9, scope: "private")

    page = Activity.feed(scopes: ["public"])

    assert Enum.all?(page.events, &(&1.kind == "node_added"))
    refute Enum.any?(page.events, &(&1.kind == "edge_reinforced"))
  end

  test "default-deny: empty scopes ⇒ NOT_FOUND, no events, no position revealed" do
    add_node!(%{type: "article", scope: "public"})

    page = Activity.feed(scopes: [])
    assert page.status == :not_found
    assert page.events == []
  end

  test "a tampered/stale cursor resyncs to the tail rather than crashing" do
    add_node!(%{type: "article", scope: "public"})

    page = Activity.feed(scopes: ["public"], cursor: "garbage-token")
    assert page.status == :found
    assert [_ev] = page.events
  end

  @tag :skip
  test "rich ER/enrichment outcomes appear once the cognitive loop runs" do
    # `entity_resolution_audit` and `enrichment_decision`/`enrichment_pass` are
    # populated only by the running workers; ActivityFeed maps them to the kinds
    # "entity_resolution" / "enrichment". Enable when the loop runs (board epic).
    flunk("loop-gated: rich activity sources need the cognitive loop running")
  end
end
