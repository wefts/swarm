defmodule Swarm.Enrichment.Scheduler do
  @moduledoc """
  The enrichment scan (workspace ADR-13 / EOS-4 §1c) — the deliberate, bounded
  trigger the budget fuse is not. A pass **snapshots** the novel, content-bearing,
  non-generated nodes, ranks them with `Swarm.Enrichment.Priority`, and enriches at
  most `max_per_pass` (the spike's blanket `content_added` reactor fired 564× from
  one seed; this fires on the few worth-it nodes, deliberately).

  **Generation-bounded convergence:** candidates are snapshotted at the START of the
  pass, so generation-N output is never input to generation-N. The output is anyway
  non-enrichable — minted entity nodes have no body (so `Priority` scores them 0)
  and claim assertions are edges, not nodes — so the worker→graph→worker loop is
  bounded by construction. A second pass over unchanged content finds the sources
  fresh-watermarked and does nothing: a fixpoint.

  Auto-scheduling is a **deliberate deployment choice** (enrichment is the
  cost-asymmetry pillar — never the continuous default); `run_pass/1` is the unit,
  invoked by an operator or a cron, off by default.
  """

  alias Swarm.Enrichment.{Priority, Worker}
  alias Swarm.Repo

  require Logger

  @typedoc "Summary of one enrichment pass (`skipped_locked` = candidates another pass held)."
  @type summary :: %{
          generation: integer(),
          considered: non_neg_integer(),
          queued: non_neg_integer(),
          enriched: non_neg_integer(),
          skipped_locked: non_neg_integer()
        }

  @doc """
  Run one bounded enrichment pass. `opts` are passed through to `Worker.enrich/2`
  (e.g. `:gen_fun`, `:model`). Returns a summary; logs each decision (codex
  observability) so an uncalibrated heuristic stays auditable.

  Per-candidate lease (council, codex): each node is CAS-claimed before enriching,
  so two overlapping passes never double-spend the LLM on the same source. The
  lease is a **row** lease (`node.lease_until`), NOT a held DB connection — the
  ~120 s model call must not pin one (a connection-held lock times out). It
  auto-expires for crash recovery. Writes are idempotent regardless, so a lost race
  costs only compute, never correctness.
  """
  @spec run_pass(keyword()) :: summary()
  def run_pass(opts \\ []) do
    cfg = Application.get_env(:swarm, :enrichment, [])
    max = cfg[:max_per_pass] || 5
    model = Keyword.get(opts, :model) || cfg[:model] || "qwen3:14b"
    policy = cfg[:policy_version] || 1
    lease_ms = cfg[:lease_ms] || 600_000
    generation = next_generation()

    candidates = novel_candidates(model, policy)
    queued = candidates |> Priority.queue(opts) |> Enum.take(max)
    worker_opts = Keyword.put(opts, :generation, generation)

    ctx = %{generation: generation, lease_ms: lease_ms, opts: worker_opts}

    {enriched, skipped} =
      Enum.reduce(queued, {0, 0}, fn {node_id, score}, {ok, sk} ->
        case enrich_candidate(node_id, score, ctx) do
          :enriched -> {ok + 1, sk}
          :locked -> {ok, sk + 1}
          :noop -> {ok, sk}
        end
      end)

    %{
      generation: generation,
      considered: length(candidates),
      queued: length(queued),
      enriched: enriched,
      skipped_locked: skipped
    }
  end

  # Lease → enrich → release one candidate. `:enriched` | `:locked` (another pass
  # holds it) | `:noop` (the worker skipped/errored — its own typed outcome).
  @spec enrich_candidate(integer(), float(), map()) :: :enriched | :locked | :noop
  defp enrich_candidate(node_id, score, %{generation: gen, lease_ms: lease_ms, opts: opts}) do
    if claim(node_id, lease_ms) do
      try do
        Logger.info(
          "enrichment: gen=#{gen} node=#{node_id} score=#{Float.round(score, 3)} — enriching"
        )

        case Worker.enrich(node_id, opts) do
          {:ok, %{edges: e}} ->
            Logger.info("enrichment: gen=#{gen} node=#{node_id} wrote #{e} claim edge(s)")
            :enriched

          other ->
            Logger.info("enrichment: gen=#{gen} node=#{node_id} → #{inspect(other)}")
            :noop
        end
      after
        release(node_id)
      end
    else
      Logger.info("enrichment: gen=#{gen} node=#{node_id} leased by another pass — skip")
      :locked
    end
  end

  # CAS-claim a node for enrichment via its lease columns (ADR-1 lease, reused).
  # A quick UPDATE — NOT a held connection — so the slow model call holds nothing.
  # Wins only if no active lease; auto-expires (crash recovery). Articles are never
  # scanned by the stagnation watchdog (`kind = 'coordination'` only), so reusing
  # `claimed_by`/`lease_until` here does not disturb coordination.
  @spec claim(integer(), pos_integer()) :: boolean()
  defp claim(node_id, lease_ms) do
    %{num_rows: n} =
      Repo.query!(
        "UPDATE node SET claimed_by = 'enrichment', " <>
          "lease_until = now() + ($2 * interval '1 millisecond') " <>
          "WHERE id = $1 AND (lease_until IS NULL OR lease_until < now())",
        [node_id, lease_ms]
      )

    n == 1
  end

  @spec release(integer()) :: :ok
  defp release(node_id) do
    Repo.query!(
      "UPDATE node SET claimed_by = NULL, lease_until = NULL WHERE id = $1 AND claimed_by = 'enrichment'",
      [node_id]
    )

    :ok
  end

  # Novel, content-bearing, non-generated nodes — the novelty gate done in SQL (one
  # indexed pass), so already-fresh nodes are never scored or re-paid. Mirrors
  # `Watermark.needs?/4`: no watermark, non-fresh, or a changed content/policy/model.
  @spec novel_candidates(String.t(), integer()) :: [integer()]
  defp novel_candidates(model, policy) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.node_id
          FROM content c
          JOIN node n ON n.id = c.node_id
          LEFT JOIN enrichment_watermark w ON w.node_id = c.node_id
         WHERE n.kind NOT IN ('claim', 'hypothesis', 'derived')
           AND length(c.body) > 0
           AND (
             w.node_id IS NULL
             OR w.state <> 'fresh'
             OR w.content_hash <> c.body_hash
             OR w.model <> $1
             OR w.policy_version <> $2
           )
        """,
        [model, policy]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  @spec next_generation() :: integer()
  defp next_generation do
    %{rows: [[g]]} =
      Repo.query!("SELECT COALESCE(max(generation), 0) + 1 FROM enrichment_watermark")

    g
  end
end
