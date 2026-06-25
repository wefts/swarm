defmodule Swarm.EntityResolution.VectorsTest do
  @moduledoc """
  Entity-resolution ER-1 — entity identity vectors. Worker-minted entities have no
  body, so the key is embedded directly to give the ANN candidate search a signal.
  The embedder is mocked (`:embed_fun`) so the write/idempotence logic is
  deterministic.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.EntityResolution.Vectors
  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp dim, do: Swarm.Config.embedding_dim()

  # A mock embedder returning a distinct constant vector per text.
  defp mock_embed do
    test = self()

    fn texts ->
      send(test, {:embedded, length(texts)})
      vectors = Enum.map(texts, fn _t -> List.duplicate(0.1, dim()) end)
      {:ok, %{vectors: vectors, namespace: "test-ns", dim: dim()}}
    end
  end

  defp vec_count do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM node WHERE type = 'entity' AND vec IS NOT NULL")

    n
  end

  describe "embed_entities/1" do
    test "embeds un-vec'd entity keys → node.vec of the configured dim" do
      Store.upsert_node("entity", "Apollo Program", scope: "public")
      Store.upsert_node("entity", "Project Apollo", scope: "public")

      assert %{embedded: 2} = Vectors.embed_entities(embed_fun: mock_embed())
      assert_received {:embedded, 2}
      assert vec_count() == 2

      %{rows: [[stamp]]} =
        Repo.query!("SELECT embed_model FROM node WHERE key = 'Apollo Program'")

      assert stamp == "test-ns"
    end

    test "is idempotent — already-vec'd entities are not re-embedded" do
      Store.upsert_node("entity", "Gemini", scope: "public")
      assert %{embedded: 1} = Vectors.embed_entities(embed_fun: mock_embed())
      assert_received {:embedded, 1}

      assert %{embedded: 0} = Vectors.embed_entities(embed_fun: mock_embed())
      refute_received {:embedded, _}
    end

    test "only entity nodes are embedded (not articles/sources)" do
      add_node!(%{type: "article", scope: "public"})
      Store.upsert_node("entity", "Mercury", scope: "public")

      assert %{embedded: 1} = Vectors.embed_entities(embed_fun: mock_embed())
      # the article has no vec and is untouched by this entity pass
      %{rows: [[arts]]} =
        Repo.query!("SELECT count(*) FROM node WHERE type='article' AND vec IS NOT NULL")

      assert arts == 0
    end

    test "an embed failure fails loud (not silently 0)" do
      Store.upsert_node("entity", "Apollo", scope: "public")
      failing = fn _texts -> {:error, :ml_down} end

      assert {:error, {:embed_failed, :ml_down}} = Vectors.embed_entities(embed_fun: failing)
    end
  end
end
