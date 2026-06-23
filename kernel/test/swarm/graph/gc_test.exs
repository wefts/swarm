defmodule Swarm.Graph.GCTest do
  @moduledoc """
  T11 — trace lifecycle. GC reaps evaporated traces (decayed below a floor) so the
  graph stays O(1), keeps reinforced ones; reinforcement is bounded (Hill ceiling,
  ADR-9) so a re-emitted trace can't lock in as a permanent attractor.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.GC
  alias Swarm.Graph.Strength
  alias Swarm.Repo

  test "reap removes evaporated traces and keeps reinforced ones" do
    a = add_node!(%{type: "file", scope: "public"})
    b = add_node!(%{type: "concept", scope: "public"})
    {:ok, _fresh} = Graph.add_edge(a, b, "mentions", "p1")
    {:ok, stale} = Graph.add_edge(a, b, "links", "p2")

    # age the stale edge far past any reinforcement → decayed strength ≈ 0
    Repo.query!("UPDATE edge SET last_seen = now() - interval '2000 days' WHERE id = $1", [
      stale.id
    ])

    assert GC.reap(floor: 0.05) == 1

    %{rows: [[remaining]]} = Repo.query!("SELECT count(*) FROM edge")
    assert remaining == 1
    %{rows: [[type]]} = Repo.query!("SELECT type FROM edge")
    assert type == "mentions"
  end

  test "reap keeps a much-reinforced OLD trace, drops an equally-old once-seen one" do
    # The reinforcement axis (not just recency): at 200 days both are old, but a
    # heavily re-seen edge's Hill strength stays above the floor while a once-seen
    # one falls below — decay-driven reap, not a flat age cutoff.
    a = add_node!(%{type: "file", scope: "public"})
    b = add_node!(%{type: "concept", scope: "public"})
    {:ok, reinforced} = Graph.add_edge(a, b, "reinforced", "p1")
    {:ok, once} = Graph.add_edge(a, b, "once", "p2")

    Repo.query!(
      "UPDATE edge SET seen_count = 1000, last_seen = now() - interval '200 days' WHERE id = $1",
      [reinforced.id]
    )

    Repo.query!("UPDATE edge SET last_seen = now() - interval '200 days' WHERE id = $1", [once.id])

    assert GC.reap(floor: 0.05) == 1

    %{rows: [[type]]} = Repo.query!("SELECT type FROM edge")
    assert type == "reinforced"
  end

  test "without reap, evaporated traces accumulate (the saturation it prevents)" do
    a = add_node!(%{type: "file", scope: "public"})
    b = add_node!(%{type: "concept", scope: "public"})
    {:ok, e} = Graph.add_edge(a, b, "mentions", "p1")
    Repo.query!("UPDATE edge SET last_seen = now() - interval '2000 days' WHERE id = $1", [e.id])

    # the stale edge is still counted until GC runs
    assert GC.saturation().edges == 1
    assert GC.reap(floor: 0.05) == 1
    assert GC.saturation().edges == 0
  end

  test "bounded weight: re-emission saturates, never reaching the ceiling (ADR-9)" do
    # Hill f(n)=ln(1+n)/(ln(1+n)+S) is monotone and bounded in [0,1): no amount of
    # reinforcement reaches 1, so a trace can't become a permanent attractor.
    assert Strength.saturation(1) < Strength.saturation(1_000)
    assert Strength.saturation(1_000_000) < 1.0
    assert Strength.strength(1_000_000, 0) < 1.0
  end
end
