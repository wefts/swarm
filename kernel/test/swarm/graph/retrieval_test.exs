defmodule Swarm.Graph.RetrievalTest do
  @moduledoc """
  Hybrid-RRF→traverse retrieval (swarm ADR-14 §5). Proves: a chunk surfaces only
  with its node identity + cited span; the scope predicate gates BOTH the lexical
  and the dense arm (a private span never leaks to a public-only asker); the dense
  arm surfaces a paraphrase the lexical arm misses; and stage-2 traversal expands
  seeds into multi-hop neighbours.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Retrieval
  alias Swarm.Graph.Store
  alias Swarm.Repo

  @dim Swarm.Config.embedding_dim()

  # A unit vector with a single 1.0 at index `i` (orthogonal for distinct i).
  defp vecn(i), do: for(j <- 0..(@dim - 1), do: if(j == i, do: 1.0, else: 0.0))

  defp node!(key, scope), do: Store.upsert_node("article", key, scope: scope)

  defp chunk!(node_id, ordinal, text, vec_index) do
    Repo.query!(
      "INSERT INTO chunk (node_id, ordinal, text, vec, embed_model) VALUES ($1, $2, $3, $4, 'fake')",
      [node_id, ordinal, text, Pgvector.new(vecn(vec_index))]
    )
  end

  defp keys(memories), do: Enum.map(memories, & &1.key)

  test "a lexical match returns the node identity with its cited span (never a bare chunk)" do
    nid = node!("Mars", "public")
    chunk!(nid, 0, "Mars is the fourth planet from the Sun", 0)

    %{status: :found, memories: [m]} =
      Retrieval.search("fourth planet", ["public"], expand: false)

    assert m.node_id == nid
    assert m.type == "article"
    assert m.key == "Mars"
    assert [%{ordinal: 0, text: text}] = m.spans
    assert text =~ "fourth planet"
    assert is_float(m.confidence)
  end

  test "the scope predicate gates the LEXICAL arm — a private span never leaks" do
    pub = node!("PubDoc", "public")
    priv = node!("PrivDoc", "private")
    chunk!(pub, 0, "shared secret topic alpha", 0)
    chunk!(priv, 0, "shared secret topic alpha extra match", 1)

    %{memories: mems} = Retrieval.search("shared secret topic alpha", ["public"], expand: false)

    assert keys(mems) == ["PubDoc"]
    refute "PrivDoc" in keys(mems)
  end

  test "the scope predicate gates the DENSE arm too" do
    pub = node!("PubV", "public")
    priv = node!("PrivV", "private")
    chunk!(pub, 0, "alpha", 5)
    chunk!(priv, 0, "beta", 5)

    # query vector is identical to BOTH chunks' vectors; only the public one may surface
    %{memories: mems} =
      Retrieval.search("nolexicalmatch", ["public"], query_vec: vecn(5), expand: false)

    assert keys(mems) == ["PubV"]
  end

  test "RRF fusion surfaces a dense paraphrase the lexical arm misses" do
    lex = node!("LexHit", "public")
    para = node!("Paraphrase", "public")
    chunk!(lex, 0, "quantum entanglement experiment", 0)
    # no shared words with the query, but its vector matches the query vector
    chunk!(para, 0, "spooky action between distant particles", 7)

    %{memories: mems} =
      Retrieval.search("quantum entanglement", ["public"], query_vec: vecn(7), expand: false)

    ks = keys(mems)
    # the dense-only paraphrase is retrieved despite zero lexical overlap
    assert "Paraphrase" in ks
    # and the lexical hit is still there → fusion, not replacement
    assert "LexHit" in ks
  end

  test "stage-2 traversal expands seeds into multi-hop neighbours" do
    seed = node!("Seed", "public")
    neighbour = node!("Neighbour", "public")
    chunk!(seed, 0, "topic about gravity waves", 0)
    {:ok, _} = Store.add_edge(seed, neighbour, "links_to", "ev1", scope: "public")

    %{status: :found, memories: mems, expanded: expanded} =
      Retrieval.search("gravity waves", ["public"], max_depth: 2)

    assert "Seed" in keys(mems)
    assert Enum.any?(expanded, &(&1.id == neighbour))
  end

  test "no asker scopes → not_found (default-deny)" do
    nid = node!("Hidden", "public")
    chunk!(nid, 0, "anything", 0)
    assert %{status: :not_found, memories: []} = Retrieval.search("anything", [], expand: false)
  end

  # --- relevance floor / answerability (the "I don't know" fix) ---

  test "a dense-only hit BELOW the relevance floor is refused → not_found" do
    nid = node!("Solo", "public")
    chunk!(nid, 0, "alpha beta gamma delta", 0)

    # query has NO lexical overlap and an ORTHOGONAL vector (cos 0 < floor) → refused
    assert %{status: :not_found, memories: []} =
             Retrieval.search("zzz nomatch qqq", ["public"], query_vec: vecn(9), expand: false)
  end

  test "a dense hit ABOVE the floor is found and reports its cosine relevance" do
    nid = node!("Topic", "public")
    chunk!(nid, 0, "alpha beta gamma delta", 0)

    %{status: :found, memories: [m]} =
      Retrieval.search("zzz nomatch qqq", ["public"], query_vec: vecn(0), expand: false)

    assert m.key == "Topic"
    assert m.relevance >= 0.9
  end

  test "a lexical (keyword) hit bypasses the floor even at zero cosine" do
    nid = node!("Keyworded", "public")
    chunk!(nid, 0, "alpha beta gamma delta", 0)

    # the word 'alpha' matches lexically; the query vector is orthogonal (cos 0)
    %{status: :found, memories: [m]} =
      Retrieval.search("alpha", ["public"], query_vec: vecn(9), expand: false)

    assert m.key == "Keyworded"
  end

  test "the floor is configurable per call" do
    nid = node!("Tunable", "public")
    chunk!(nid, 0, "alpha beta gamma delta", 0)

    # cos is 1.0 for an identical vector; a floor above 1.0 refuses everything dense
    assert %{status: :not_found} =
             Retrieval.search("zzz qqq", ["public"], query_vec: vecn(0), floor: 1.01, expand: false)
  end
end
