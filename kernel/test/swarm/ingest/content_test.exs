defmodule Swarm.Ingest.ContentTest do
  @moduledoc """
  The content/chunk writer (swarm ADR-14 §2). Phase A (`put_body`) persists the
  raw body + hash and signals `content_added`; Phase B (`embed`) segments, embeds
  (injected, deterministic), writes ordered chunks, and aggregates `node.vec`. The
  aggregate is a true element-wise mean, the embed is idempotent, and a chunk is
  never written without its node + ordinal.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Ingest.Content
  alias Swarm.Repo

  @dim Swarm.Config.embedding_dim()

  defp node!(key), do: Store.upsert_node("article", key, scope: "public")

  # A deterministic fake embedder: one @dim-wide vector per text whose first
  # component is the supplied per-text value, so the mean is checkable.
  defp fake_embedder(values) do
    fn texts ->
      vectors =
        texts
        |> Enum.with_index()
        |> Enum.map(fn {_t, i} -> [Enum.at(values, i, 0.0) | List.duplicate(0.0, @dim - 1)] end)

      {:ok, vectors, "fake-bge-m3"}
    end
  end

  test "put_body persists body + hash and emits a content_added signal; blank is skipped" do
    nid = node!("Body Page")

    assert :ok = Content.put_body(nid, "the body text", source_ref: "wikipedia:1")

    %{rows: [[body, hash, seg, ref]]} =
      Repo.query!(
        "SELECT body, body_hash, segmenter, source_ref FROM content WHERE node_id = $1",
        [nid]
      )

    assert body == "the body text"
    assert hash == Content.body_hash("the body text")
    assert seg == "structured-v1"
    assert ref == "wikipedia:1"

    assert Repo.query!(
             "SELECT count(*) FROM outbox WHERE change = 'content_added' AND idem_key = $1",
             ["content:#{nid}"]
           ).rows == [[1]]

    assert Content.put_body(node!("Empty Page"), "   ") == :skip
  end

  test "put_body overwrites on a changed body (idempotent on node_id)" do
    nid = node!("Reedit")
    Content.put_body(nid, "first")
    Content.put_body(nid, "second")

    assert Repo.query!("SELECT body FROM content WHERE node_id = $1", [nid]).rows == [["second"]]
    assert Repo.query!("SELECT count(*) FROM content WHERE node_id = $1", [nid]).rows == [[1]]
  end

  test "embed segments, writes ordered chunks, and aggregates node.vec as the mean" do
    nid = node!("Embed Page")
    Content.put_body(nid, "para one here\n\npara two here\n\npara three here")

    # max_tokens 3 → three windows; vec first-components 1.0, 3.0, 5.0 → mean 3.0
    assert {:ok, 3} =
             Content.embed(nid, max_tokens: 3, embed_fun: fake_embedder([1.0, 3.0, 5.0]))

    %{rows: rows} =
      Repo.query!(
        "SELECT ordinal, text, embed_model, token_count FROM chunk WHERE node_id = $1 ORDER BY ordinal",
        [nid]
      )

    assert length(rows) == 3
    assert Enum.map(rows, fn [o | _] -> o end) == [0, 1, 2]
    assert Enum.all?(rows, fn [_, _, model, _] -> model == "fake-bge-m3" end)

    %{rows: [[vec, model]]} =
      Repo.query!("SELECT vec, embed_model FROM node WHERE id = $1", [nid])

    assert model == "fake-bge-m3"
    assert hd(Pgvector.to_list(vec)) == 3.0
  end

  test "embed is idempotent — re-embedding replaces chunks, not appends" do
    nid = node!("Reembed Page")
    Content.put_body(nid, "alpha\n\nbeta\n\ngamma")

    assert {:ok, 3} = Content.embed(nid, max_tokens: 1, embed_fun: fake_embedder([1.0, 1.0, 1.0]))
    assert {:ok, 3} = Content.embed(nid, max_tokens: 1, embed_fun: fake_embedder([2.0, 2.0, 2.0]))

    assert Repo.query!("SELECT count(*) FROM chunk WHERE node_id = $1", [nid]).rows == [[3]]
  end

  test "embed on a node with no content is a no-op" do
    nid = node!("No Body")
    assert {:ok, :no_content} = Content.embed(nid, embed_fun: fake_embedder([]))
    assert Repo.query!("SELECT count(*) FROM chunk WHERE node_id = $1", [nid]).rows == [[0]]
  end

  test "a transient embed failure is returned, leaving the body for retry" do
    nid = node!("Flaky")
    Content.put_body(nid, "some body")
    failing = fn _ -> {:error, :down} end

    assert {:error, :down} = Content.embed(nid, embed_fun: failing)
    # body survives; no partial chunks
    assert Repo.query!("SELECT count(*) FROM content WHERE node_id = $1", [nid]).rows == [[1]]
    assert Repo.query!("SELECT count(*) FROM chunk WHERE node_id = $1", [nid]).rows == [[0]]
  end
end
