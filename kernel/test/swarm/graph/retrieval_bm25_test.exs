defmodule Swarm.Graph.RetrievalBm25Test do
  @moduledoc """
  ADR-0016: the pg_search (Tantivy BM25) lexical arm, selected by
  `config :swarm, :retrieval, lexical_engine: :bm25`. Proves — on a pg_search-capable
  Postgres — that the bm25 arm (a) surfaces a title-only page a body-lexical arm can't,
  (b) enforces scope IN-index (no cross-scope leak). Skipped automatically where
  pg_search is absent (plain pgvector), so the suite stays portable.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Retrieval
  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp pg_search? do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM pg_extension WHERE extname = 'pg_search'", [])

    n > 0
  end

  defp chunk!(node_id, ordinal, text),
    do:
      Repo.query!("INSERT INTO chunk (node_id, ordinal, text) VALUES ($1, $2, $3)", [
        node_id,
        ordinal,
        text
      ])

  defp keys(mems), do: Enum.map(mems, & &1.key)

  setup do
    if pg_search?() do
      prev = Application.get_env(:swarm, :retrieval, [])
      Application.put_env(:swarm, :retrieval, Keyword.put(prev, :lexical_engine, :bm25))
      on_exit(fn -> Application.put_env(:swarm, :retrieval, prev) end)
      :ok
    else
      {:skip, "pg_search not installed"}
    end
  end

  test "bm25 arm surfaces a title-only page with no body lexical overlap" do
    # The answer page's TITLE is the query target; its body shares no query lexeme.
    # A body-lexical arm can't reach it; bm25's title field-boost scores the title
    # match on its own, so the page surfaces (the native arm's structural gap).
    kube = Store.upsert_node("article", "KUBERNETES", scope: "group")
    chunk!(kube, 0, "cluster provisioning request form fields")

    %{memories: mems} =
      Retrieval.search("kubernetes", ["group"], dense: false, expand: false)

    assert "KUBERNETES" in keys(mems)
  end

  test "the bm25 arm enforces scope IN-index — a private page never leaks" do
    priv = Store.upsert_node("article", "KUBERNETES", scope: "private")
    chunk!(priv, 0, "cluster provisioning request form fields")

    %{memories: mems} =
      Retrieval.search("kubernetes", ["group"], dense: false, expand: false)

    refute "KUBERNETES" in keys(mems)
  end

  test "bm25 body match still returns the node identity + cited span" do
    nid = Store.upsert_node("article", "Mars", scope: "group")
    chunk!(nid, 0, "Mars is the fourth planet from the Sun")

    %{status: :found, memories: [m]} =
      Retrieval.search("fourth planet", ["group"], dense: false, expand: false)

    assert m.key == "Mars"
    assert [%{ordinal: 0, text: text}] = m.spans
    assert text =~ "fourth planet"
  end
end
