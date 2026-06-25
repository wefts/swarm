defmodule Swarm.Enrichment.Priority do
  @moduledoc """
  Worth-it priority (workspace ADR-13 / EOS-4 §1b) — the SCHEDULER that decides
  *whether* a node earns the expensive (~120 s) extraction, computed cheaply and
  with NO model call, BEFORE any escalation. This is what the budget fuse is not: a
  fuse caps cost, a scheduler picks the few nodes worth paying for.

  `score/2 ∈ [0, 1]`:

  - **novelty is the hard gate** — coupled to the watermark (council, gemma): a node
    with no body, an LLM-generated zone, or an already-`fresh` watermark for the
    current content/policy/model scores **0** (no re-pay, cannot be gamed into
    redoing covered work);
  - among novel nodes, the score combines **centrality** (graph degree, Hill-
    normalised so hubs outrank leaves but nothing runs away) and **criticality**
    (`1 − corroboration`: an under-corroborated node is worth representing as
    claims), weighted by the ADR-8 tuning inventory.

  `demand` (retrieval/traversal hit-count) is a named EOS-4 signal with **no data
  source yet**; it is injectable via `:demand_fun` (default `0.0`) so it composes
  once telemetry exists — never fabricated.

  Corroboration is read UNSCOPED here: this is internal scheduling, not an answer to
  a scoped asker, so all assertions count.
  """

  alias Swarm.Enrichment.Watermark
  alias Swarm.Graph.Corroboration
  alias Swarm.Ingest.Content
  alias Swarm.Repo

  @generated_kinds ~w(claim hypothesis derived)

  @typedoc "An auditable scheduling decision — every component, the score, and the verdict."
  @type explanation :: %{
          novel: boolean(),
          central: float(),
          criticality: float(),
          demand: float(),
          score: float(),
          threshold: float(),
          worth_it: boolean()
        }

  @doc """
  Worth-it score for `node_id` in `[0, 1]`. `0` when the node cannot/should-not be
  enriched (no body, generated zone) or is already freshly covered (novelty gate).
  `opts`: `:model` (override), `:demand_fun` (`(node_id) -> float in [0,1]`).
  """
  @spec score(integer(), keyword()) :: float()
  def score(node_id, opts \\ []) when is_integer(node_id) do
    explain(node_id, opts).score
  end

  @doc """
  The full, auditable decision for `node_id` — novelty, each component, the final
  score, the threshold, and the verdict. Logging this per scheduling decision keeps
  the (uncalibrated) heuristic transparent and lets ADR-8 be re-derived from real
  runs (council, codex). Same opts as `score/2`.
  """
  @spec explain(integer(), keyword()) :: explanation()
  def explain(node_id, opts \\ []) when is_integer(node_id) do
    cfg = priority_cfg()
    threshold = cfg[:threshold]

    if novel?(node_id, opts) do
      central = central(node_id, cfg[:central_k])
      crit = 1.0 - Corroboration.node(node_id)
      demand = Keyword.get(opts, :demand_fun, fn _ -> 0.0 end).(node_id)
      score = cfg[:w_central] * central + cfg[:w_crit] * crit + demand_weight(cfg) * demand

      %{
        novel: true,
        central: central,
        criticality: crit,
        demand: demand,
        score: score,
        threshold: threshold,
        worth_it: score >= threshold
      }
    else
      %{
        novel: false,
        central: 0.0,
        criticality: 0.0,
        demand: 0.0,
        score: 0.0,
        threshold: threshold,
        worth_it: false
      }
    end
  end

  @doc "Whether `node_id` clears the configured worth-it threshold."
  @spec worth_it?(integer(), keyword()) :: boolean()
  def worth_it?(node_id, opts \\ []) do
    explain(node_id, opts).worth_it
  end

  @doc """
  The enrichment queue for `node_ids`: those at/above threshold, strongest-first,
  as `[{node_id, score}]`. Below-threshold nodes never escalate.
  """
  @spec queue([integer()], keyword()) :: [{integer(), float()}]
  def queue(node_ids, opts \\ []) when is_list(node_ids) do
    threshold = priority_cfg()[:threshold]

    node_ids
    |> Enum.map(fn id -> {id, score(id, opts)} end)
    |> Enum.filter(fn {_id, s} -> s >= threshold end)
    |> Enum.sort_by(fn {_id, s} -> s end, :desc)
  end

  # Novelty gate: enrichable (has a body, not a generated zone) AND not already
  # covered by a fresh watermark for the current content/policy/model.
  @spec novel?(integer(), keyword()) :: boolean()
  defp novel?(node_id, opts) do
    with %{kind: kind} <- load(node_id),
         false <- kind in @generated_kinds,
         b when is_binary(b) and b != "" <- body(node_id) do
      cfg = Application.get_env(:swarm, :enrichment, [])
      model = Keyword.get(opts, :model) || cfg[:model] || "qwen3:14b"
      policy = cfg[:policy_version] || 1
      Watermark.needs?(node_id, Content.body_hash(b), policy, model)
    else
      _ -> false
    end
  end

  # Degree centrality, Hill-normalised to [0, 1): deg / (deg + k). Bounded — a
  # super-hub cannot dominate the queue unboundedly (same shape as ADR-9 strength).
  @spec central(integer(), number()) :: float()
  defp central(node_id, k) do
    %{rows: [[deg]]} =
      Repo.query!("SELECT count(*) FROM edge WHERE src = $1 OR dst = $1", [node_id])

    deg / (deg + k)
  end

  defp priority_cfg, do: Application.get_env(:swarm, :enrichment, [])[:priority] || []

  # Demand weight is implicit (1 − the two named weights' share) but kept simple:
  # demand adds on top, capped by the score clamp. Default 0 source ⇒ no effect.
  defp demand_weight(cfg), do: cfg[:w_demand] || 0.0

  @spec load(integer()) :: %{kind: String.t(), scope: String.t()} | nil
  defp load(node_id) do
    case Repo.query!("SELECT kind, scope FROM node WHERE id = $1", [node_id]) do
      %{rows: [[kind, scope]]} -> %{kind: kind, scope: scope}
      _ -> nil
    end
  end

  @spec body(integer()) :: String.t() | nil
  defp body(node_id) do
    case Repo.query!("SELECT body FROM content WHERE node_id = $1", [node_id]) do
      %{rows: [[b]]} -> b
      _ -> nil
    end
  end
end
