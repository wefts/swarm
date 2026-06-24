defmodule Swarm.Ingest.Content do
  @moduledoc """
  The content/chunk side-store writer (swarm ADR-14 §2). Two phases, deliberately
  split so the network call never sits inside the ingest transaction:

  - **`put_body/3`** — deterministic, cheap, runs *inside* the ingest tx: writes
    the raw `content` row (body + `body_hash`) for a node and emits a
    `content_added` stigmergy signal. No segmentation, no embedding, no network.
  - **`embed/2`** — the worker step: reads the stored body, segments it
    (`Swarm.Ingest.Segmenter`), embeds each partition (one cheap bge-m3 pass), writes
    the `chunk` rows, and aggregates the partition vectors into `node.vec`. The
    embedder is injectable (`:embed_fun`) so tests run deterministically and the
    live path uses the real ML boundary. Idempotent: re-embedding a node replaces
    its chunks (re-embed on body change).

  No LLM anywhere on this path — segmentation and embedding are the only steps.
  """

  alias Swarm.Ingest.Segmenter
  alias Swarm.ML.Embeddings
  alias Swarm.Repo

  require Logger

  @typedoc "Embedder contract: texts in, one vector per text + the model namespace."
  @type embed_fun :: ([String.t()] -> {:ok, [[float()]], String.t()} | {:error, term()})

  @doc """
  Persist a node's raw body (Phase A — inside the ingest tx). Idempotent on
  `node_id` (the content PK): a changed body overwrites. Emits `content_added` so
  the embed worker (or the live path) can react. A blank body is a no-op.
  """
  @spec put_body(integer(), String.t(), keyword()) :: :ok | :skip
  def put_body(node_id, body, opts \\ []) when is_integer(node_id) and is_binary(body) do
    if String.trim(body) == "" do
      :skip
    else
      source_ref = Keyword.get(opts, :source_ref)

      Repo.query!(
        """
        INSERT INTO content (node_id, body, body_hash, source_ref, segmenter)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (node_id)
        DO UPDATE SET body = $2, body_hash = $3, source_ref = $4, segmenter = $5, created_at = now()
        """,
        [node_id, body, body_hash(body), source_ref, Segmenter.name()]
      )

      emit_content_added(node_id)
      :ok
    end
  end

  @doc """
  Segment + embed a node's stored body into `chunk` rows and aggregate `node.vec`
  (Phase B — the worker step, outside the ingest tx). `opts[:embed_fun]` injects
  the embedder (default: the real ML boundary). Returns `{:ok, n_chunks}`,
  `{:ok, :no_content}` if the node has no body, or `{:error, reason}` (the body is
  preserved, so a transient embed failure can be retried).
  """
  @spec embed(integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:ok, :no_content} | {:error, term()}
  def embed(node_id, opts \\ []) when is_integer(node_id) do
    case body(node_id) do
      nil ->
        {:ok, :no_content}

      body ->
        embed_fun = Keyword.get(opts, :embed_fun, &default_embed/1)

        case Segmenter.segment(body, opts) do
          [] -> {:ok, :no_content}
          parts -> embed_parts(node_id, parts, embed_fun)
        end
    end
  end

  @doc "SHA-256 hex digest of a body — the exact-duplicate key on `content.body_hash`."
  @spec body_hash(String.t()) :: String.t()
  def body_hash(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  # --- internals -------------------------------------------------------------

  @spec embed_parts(integer(), [String.t()], embed_fun()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp embed_parts(node_id, parts, embed_fun) do
    case embed_fun.(parts) do
      {:ok, vectors, model} when length(vectors) == length(parts) ->
        write_chunks(node_id, parts, vectors, model)
        set_node_vec(node_id, vectors, model)
        {:ok, length(parts)}

      {:ok, vectors, _model} ->
        {:error, {:vector_count_mismatch, expected: length(parts), got: length(vectors)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Replace the node's chunks atomically (idempotent re-embed), then bulk-insert
  # the new ordered spans with their vectors.
  @spec write_chunks(integer(), [String.t()], [[float()]], String.t()) :: :ok
  defp write_chunks(node_id, parts, vectors, model) do
    Repo.transaction(fn ->
      Repo.query!("DELETE FROM chunk WHERE node_id = $1", [node_id])

      parts
      |> Enum.zip(vectors)
      |> Enum.with_index()
      |> Enum.each(fn {{text, vec}, ordinal} ->
        Repo.query!(
          """
          INSERT INTO chunk (node_id, ordinal, text, vec, embed_model, token_count)
          VALUES ($1, $2, $3, $4, $5, $6)
          """,
          [node_id, ordinal, text, Pgvector.new(vec), model, Segmenter.token_count(text)]
        )
      end)
    end)

    :ok
  end

  # `node.vec` is the deterministic mean of its chunk vectors (the aggregate form,
  # §2.3) — a cheap recompute when the chunk set changes. The per-type
  # aggregate-vs-identity choice is a Phase-2 recall measurement; the aggregate is
  # the Phase-1 default.
  @spec set_node_vec(integer(), [[float()]], String.t()) :: :ok
  defp set_node_vec(node_id, vectors, model) do
    Repo.query!("UPDATE node SET vec = $2, embed_model = $3, updated_at = now() WHERE id = $1", [
      node_id,
      Pgvector.new(mean(vectors)),
      model
    ])

    :ok
  end

  @spec mean([[float()]]) :: [float()]
  defp mean([single]), do: single

  defp mean(vectors) do
    n = length(vectors)

    vectors
    |> Enum.zip_with(&Enum.sum/1)
    |> Enum.map(&(&1 / n))
  end

  @spec body(integer()) :: String.t() | nil
  defp body(node_id) do
    case Repo.query!("SELECT body FROM content WHERE node_id = $1", [node_id]) do
      %{rows: [[body]]} -> body
      _ -> nil
    end
  end

  # The real embedder: one batch round-trip to the Python ML pillar. Adapts the
  # boundary's `{:ok, %{vectors, namespace}}` to the injectable `embed_fun` shape.
  @spec default_embed([String.t()]) :: {:ok, [[float()]], String.t()} | {:error, term()}
  defp default_embed(texts) do
    case Embeddings.embed(texts) do
      {:ok, %{vectors: vectors, namespace: ns}} -> {:ok, vectors, ns}
      {:error, reason} -> {:error, reason}
    end
  end

  # Stigmergy signal (swarm ADR-2): a node now carries content to be embedded.
  # Emitted inside the caller's tx so it commits with the content row. Keyed by
  # node so re-ingesting the same node coalesces on `idem_key`.
  @spec emit_content_added(integer()) :: :ok
  defp emit_content_added(node_id) do
    Repo.query!(
      "INSERT INTO outbox (change, target_key, payload, idem_key) VALUES ($1, $2, $3::jsonb, $4)",
      [
        "content_added",
        "node:#{node_id}",
        Jason.encode!(%{node_id: node_id}),
        "content:#{node_id}"
      ]
    )

    Repo.query!("SELECT pg_notify('stigmergy', '')")
    :ok
  end
end
