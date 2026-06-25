defmodule Swarm.Ingest.Embedder do
  @moduledoc """
  The embed worker (swarm ADR-14 §2, Phase B). Reacts to the `content_added`
  stigmergy signal: for the node named in the row, segment its stored body, embed
  the partitions, write the `chunk` rows, and aggregate `node.vec`
  (`Swarm.Ingest.Content.embed/2`). This is the cheap, continuous specialized
  process the architecture calls for — embedding happens off the ingest
  transaction, driven by the graph write, not synchronously in `upsert_node`.

  Idempotent on the node (re-embedding replaces its chunks), which matches the
  tailer's at-least-once delivery. A transient embed failure returns `{:error, …}`
  and leaves the body in place for a later retry — it never quarantines content.

  Subscribe it via `Swarm.Stigmergy.Dispatch.subscribe("content_added", &handle/1)`
  in the deployed runtime; tests drive `Swarm.Ingest.Content.embed/2` directly with
  an injected embedder.
  """

  @behaviour Swarm.Ports.Worker

  alias Swarm.Ingest.Content

  require Logger

  @impl Swarm.Ports.Worker
  def handle(%{payload: %{"node_id" => node_id}}) when is_integer(node_id) do
    case Content.embed(node_id) do
      {:ok, n} when is_integer(n) ->
        {:ok, %{node_id: node_id, chunks: n}}

      {:ok, :no_content} ->
        {:ok, %{node_id: node_id, chunks: 0}}

      {:ok, :unchanged} ->
        # Body already embedded (write-amplification bound, ADR-14 §7) — a no-op.
        {:ok, %{node_id: node_id, chunks: 0}}

      {:error, reason} ->
        Logger.warning("embedder: node #{node_id} embed failed — #{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle(row) do
    {:error, {:unexpected_row, row}}
  end

  @impl Swarm.Ports.Worker
  def describe, do: %{name: "embedder", handles: ["content_added"]}
end
