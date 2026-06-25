defmodule Swarm.Enrichment.Watermark do
  @moduledoc """
  Durable enrichment watermark (workspace ADR-13 / EOS-4 §1a) — the gate that keeps
  the ~120 s extraction rare. It records what was enriched and under WHICH content
  + policy + model, so re-seeing an unchanged node does not re-pay.

  Content-sensitive + invalidatable (council, codex): `needs?/4` is true when there
  is no watermark, OR the body content changed (`content_hash`), OR the extraction
  `policy_version`/`model` was bumped, OR the last attempt is not `fresh` (a
  `stale`/`retry`/`error` row must be retried). An unchanged `fresh` node is **not**
  re-enriched — the scheduler (EW-4) does not even pay to consider it novel.
  """

  alias Swarm.Repo

  @typedoc "What an enrichment run records: the content + policy + model it ran under."
  @type stamp :: %{
          content_hash: String.t(),
          policy_version: integer(),
          model: String.t(),
          generation: integer(),
          state: String.t()
        }

  @doc """
  Should `node_id` be (re-)enriched for this content/policy/model? True when no
  fresh watermark covers exactly `(content_hash, policy_version, model)`.
  """
  @spec needs?(integer(), String.t(), integer(), String.t()) :: boolean()
  def needs?(node_id, content_hash, policy_version, model) do
    case Repo.query!(
           "SELECT content_hash, policy_version, model, state FROM enrichment_watermark WHERE node_id = $1",
           [node_id]
         ) do
      %{rows: []} ->
        true

      %{rows: [[hash, policy, m, state]]} ->
        state != "fresh" or hash != content_hash or policy != policy_version or m != model
    end
  end

  @doc "Upsert the watermark for `node_id` (idempotent on the node_id PK)."
  @spec record(integer(), stamp()) :: :ok
  def record(node_id, %{} = stamp) do
    Repo.query!(
      """
      INSERT INTO enrichment_watermark
        (node_id, content_hash, policy_version, model, generation, state, enriched_at)
      VALUES ($1, $2, $3, $4, $5, $6, now())
      ON CONFLICT (node_id) DO UPDATE SET
        content_hash = $2, policy_version = $3, model = $4,
        generation = $5, state = $6, enriched_at = now()
      """,
      [
        node_id,
        stamp.content_hash,
        stamp.policy_version,
        stamp.model,
        stamp.generation,
        stamp.state
      ]
    )

    :ok
  end

  @doc "The recorded generation for `node_id`, or 0 if never enriched (EW-5 uses this)."
  @spec generation(integer()) :: integer()
  def generation(node_id) do
    case Repo.query!("SELECT generation FROM enrichment_watermark WHERE node_id = $1", [node_id]) do
      %{rows: [[g]]} -> g
      _ -> 0
    end
  end
end
