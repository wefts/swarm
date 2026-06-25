defmodule Swarm.EntityResolution.Vectors do
  @moduledoc """
  Entity identity vectors (entity-resolution soft-match, ER-1; swarm ADR-13 §3.2).

  Worker-minted `entity` nodes have no body, so the content→chunk→`node.vec` path
  never runs and they have no vector for the ANN candidate search (ER-2) to match.
  An entity's identity vector is the embedding of its **key** (surface form) — the
  same signal the cognitive-activation spike used to surface near-duplicate pairs.

  This is a cheap, bounded, idempotent pass (no LLM): embed the keys of un-vec'd
  entity nodes in one batch and stamp `node.vec` (+ the ADR-6 embedding namespace).
  The vector is scope-agnostic identity; scope is applied later, at propose time.
  """

  alias Swarm.ML.Embeddings
  alias Swarm.Repo

  @doc """
  Embed the keys of up to `:limit` un-vec'd `entity` nodes → `node.vec`. Returns
  `%{embedded: n}` (0 when none remain — idempotent), or a typed `{:error, reason}`
  (fail-loud; an embed failure is not silently "0 embedded"). `:embed_fun` (default
  `Swarm.ML.Embeddings.embed/1`) is injectable for tests.
  """
  @spec embed_entities(keyword()) :: %{embedded: non_neg_integer()} | {:error, term()}
  def embed_entities(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    embed = Keyword.get(opts, :embed_fun, &Embeddings.embed/1)

    %{rows: rows} =
      Repo.query!(
        "SELECT id, key FROM node WHERE type = 'entity' AND vec IS NULL ORDER BY id LIMIT $1",
        [limit]
      )

    case rows do
      [] -> %{embedded: 0}
      rows -> embed_batch(rows, embed)
    end
  end

  @spec embed_batch([[term()]], fun()) :: %{embedded: non_neg_integer()} | {:error, term()}
  defp embed_batch(rows, embed) do
    keys = Enum.map(rows, fn [_id, key] -> key end)

    case embed.(keys) do
      {:ok, %{vectors: vectors, namespace: namespace}} when length(vectors) == length(rows) ->
        rows
        |> Enum.zip(vectors)
        |> Enum.each(fn {[id, _key], vec} ->
          Repo.query!(
            "UPDATE node SET vec = $2, embed_model = $3, updated_at = now() WHERE id = $1",
            [id, Pgvector.new(vec), namespace]
          )
        end)

        %{embedded: length(rows)}

      {:ok, _mismatch} ->
        {:error, :embedding_count_mismatch}

      {:error, reason} ->
        {:error, {:embed_failed, reason}}
    end
  end
end
