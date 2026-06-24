defmodule Swarm.Connector.WikipediaTest do
  @moduledoc """
  The public Wikipedia (MediaWiki) reference connector (swarm ADR-5), proven
  end-to-end against RECORDED API responses — no network. Covers the `fetch/2`
  contract through `Connector.Sync`, the internal link graph, the idempotent
  stub→page merge (entity resolution), namespace/self-link rejection, and the
  no-silent-cap truncation behaviour.

  Live-data surprises (alias/redirect/disambiguation fragmentation) are frozen
  as regression fixtures HERE as they are discovered on the live slice.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Connector.Sync
  alias Swarm.Repo
  alias Swarm.Test.WikipediaConnector, as: Wiki

  # --- recorded fixtures (formatversion=2: pages is a list) ------------------

  defp page(id, title, wikitext) do
    %{
      "pageid" => id,
      "title" => title,
      "fullurl" => "https://en.wikipedia.org/wiki/#{String.replace(title, " ", "_")}",
      "revisions" => [
        %{"timestamp" => "2024-05-01T12:00:00Z", "slots" => %{"main" => %{"content" => wikitext}}}
      ]
    }
  end

  # Page 1: "Apollo program" (links: Apollo 11, NASA, Saturn V, a Category [skip],
  # and a self-link via anchor [skip]) and "NASA" (links: Apollo program [back],
  # United States).
  defp body_page1 do
    JSON.encode!(%{
      "continue" => %{"gapcontinue" => "Apollo_11", "continue" => "gapcontinue||"},
      "query" => %{
        "pages" => [
          page(
            10,
            "Apollo program",
            "The [[Apollo 11]] mission by [[NASA]] used the [[Saturn V]] rocket. " <>
              "See [[Category:Spaceflight]] and [[Apollo_program#History|history]]."
          ),
          page(20, "NASA", "[[Apollo program]] is run by [[NASA]] in the [[United States]].")
        ]
      }
    })
  end

  # Page 2: "Apollo 11" (links: Apollo program [back], Moon). No continue → done.
  defp body_page2 do
    JSON.encode!(%{
      "query" => %{
        "pages" => [
          page(30, "Apollo 11", "[[Apollo program]] landed humans on the [[Moon]].")
        ]
      }
    })
  end

  # An injectable HTTP that serves page1 then page2 by inspecting the cursor in
  # the URL (page 2 carries the gapcontinue token).
  defp fixture_http do
    fn url ->
      if String.contains?(url, "gapcontinue=Apollo_11"),
        do: {:ok, body_page2()},
        else: {:ok, body_page1()}
    end
  end

  defp node_keys(type \\ "article") do
    %{rows: rows} = Repo.query!("SELECT key FROM node WHERE type = $1 ORDER BY key", [type])
    Enum.map(rows, fn [k] -> k end)
  end

  defp edge_count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM edge WHERE type = 'links_to'")
    n
  end

  # --- contract / pagination -------------------------------------------------

  test "full sync paginates the continue token to exhaustion and ingests every page" do
    {:ok, r} = Sync.run(Wiki, http: fixture_http(), resolve_redirects: false)

    assert r.mode == :full
    assert r.complete?
    assert r.pages == 2
    # three real source pages → three written events
    assert r.ingested == 3
  end

  test "link target stub and its own page resolve to ONE node (idempotent merge)" do
    {:ok, _} = Sync.run(Wiki, http: fixture_http(), resolve_redirects: false)

    keys = node_keys()
    # "Apollo 11" is a link target on page 1 AND its own page on page 2 → one node.
    assert "Apollo 11" in keys
    assert Enum.count(keys, &(&1 == "Apollo 11")) == 1
    # real pages + stubs, all scope public, all type article
    assert "Apollo program" in keys
    assert "NASA" in keys
    assert "Saturn V" in keys
    assert "United States" in keys
    assert "Moon" in keys
  end

  test "non-article namespace links and self-links are rejected" do
    {:ok, _} = Sync.run(Wiki, http: fixture_http(), resolve_redirects: false)
    keys = node_keys()

    # Category: namespace link is not an article node.
    refute Enum.any?(keys, &String.starts_with?(&1, "Category"))
    # The self-link [[Apollo_program#History]] canonicalises to the page title and
    # is dropped — there is no Apollo-program → Apollo-program edge.
    %{rows: [[self_loops]]} =
      Repo.query!("SELECT count(*) FROM edge e WHERE e.src = e.dst AND e.type = 'links_to'")

    assert self_loops == 0
  end

  test "links_to edges are written between articles and are public-scoped" do
    {:ok, _} = Sync.run(Wiki, http: fixture_http(), resolve_redirects: false)

    # Apollo program → {Apollo 11, NASA, Saturn V}; NASA → {Apollo program, United States};
    # Apollo 11 → {Apollo program, Moon}. (Self/category dropped.) = 7 edges.
    assert edge_count() == 7

    %{rows: [[bad_scope]]} =
      Repo.query!("SELECT count(*) FROM edge WHERE visibility_scope <> 'public'")

    assert bad_scope == 0
  end

  test "our own page ceiling surfaces as truncation (no silent cap)" do
    {:ok, r} = Sync.run(Wiki, http: fixture_http(), resolve_redirects: false, max_pages: 1)

    # Stopped after one API page while a continue token still existed.
    assert r.pages == 1
    refute r.complete?
    assert r.ceilings == 1
  end

  # --- swarm ADR-13 layer 2: redirect resolution at the connector --------------

  test "redirect resolution collapses an alias link target onto the canonical page" do
    # Page links to the redirect alias "Allmusic"; the resolve query maps it to the
    # canonical "AllMusic". With resolution ON, only the canonical node is created.
    redirect_body =
      JSON.encode!(%{
        "query" => %{"redirects" => [%{"from" => "Allmusic", "to" => "AllMusic"}], "pages" => []}
      })

    allpages_body =
      JSON.encode!(%{
        "query" => %{"pages" => [page(40, "Some Band", "Reviewed on [[Allmusic]] and [[NASA]].")]}
      })

    http = fn url ->
      if String.contains?(url, "redirects=1"),
        do: {:ok, redirect_body},
        else: {:ok, allpages_body}
    end

    {:ok, _} = Sync.run(Wiki, http: http, resolve_redirects: true)
    keys = node_keys()

    assert "AllMusic" in keys
    refute "Allmusic" in keys

    %{rows: [[n]]} =
      Repo.query!("""
      SELECT count(*) FROM edge e
      JOIN node s ON s.id = e.src JOIN node d ON d.id = e.dst
      WHERE s.key = 'Some Band' AND d.key = 'AllMusic' AND e.type = 'links_to'
      """)

    assert n == 1
  end

  # --- pure unit: canonicalisation + extraction (the entity-resolution seam) --

  test "canonical_title normalises underscores, anchors, whitespace, first-letter case" do
    assert Wiki.canonical_title("apollo_program") == "Apollo program"
    assert Wiki.canonical_title("Apollo program#History") == "Apollo program"
    assert Wiki.canonical_title("  Saturn   V  ") == "Saturn V"
    assert Wiki.canonical_title("united_States") == "United States"
  end

  test "link_targets extracts article targets, drops namespaces and anchors" do
    wt =
      "[[Apollo 11]] and [[NASA|the agency]] and [[Saturn V]] " <>
        "[[Category:Spaceflight]] [[File:x.png]] [[Moon#Phases]]"

    targets = Wiki.link_targets(wt)

    assert "Apollo 11" in targets
    assert "NASA" in targets
    assert "Saturn V" in targets
    assert "Moon" in targets
    refute Enum.any?(targets, &String.contains?(&1, "Category"))
    refute Enum.any?(targets, &String.contains?(&1, "File"))
  end

  # --- entity-resolution: the two fragmentation classes the live slice found ---
  # Both classes (risk #1) are now addressed (swarm ADR-13): percent-encoding in
  # canonical_title (layer 1, below), internal-case/redirect via redirect resolution
  # (layer 2, the "redirect resolution collapses…" test above). These pin the
  # behaviour so a regression re-fragments loudly. See board/journal.md.

  test "BOUNDARY: canonical_title alone cannot fold internal-case (that needs redirect resolution)" do
    # canonical_title only uppercases the FIRST letter (MediaWiki's real rule), so
    # in isolation it does NOT fold "Allmusic"/"AllMusic" — by design. The fold
    # happens a layer up, via resolve_titles/redirect resolution (tested above),
    # because only the source knows these are one page. This documents the split.
    assert Wiki.canonical_title("Allmusic") == "Allmusic"
    assert Wiki.canonical_title("AllMusic") == "AllMusic"
    assert Wiki.canonical_title("Allmusic") != Wiki.canonical_title("AllMusic")
  end

  test "FIXED (swarm ADR-13 layer 1): percent-encoded targets resolve to the plain title" do
    # canonical_title now URL-decodes, so the encoded link target and the plain
    # page title collapse to ONE node. (Was a KNOWN-GAP on the first live slice.)
    assert Wiki.canonical_title("%21%21%21 (album)") == "!!! (album)"
    assert Wiki.canonical_title("%21%21%21 (album)") == Wiki.canonical_title("!!! (album)")
    # a lone % in a legitimate title is left untouched (no false rewrite)
    assert Wiki.canonical_title("100% (song)") == "100% (song)"
  end
end
