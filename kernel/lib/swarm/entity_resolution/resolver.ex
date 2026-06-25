defmodule Swarm.EntityResolution.Resolver do
  @moduledoc """
  Entity-resolution soft-match driver (ER-3) — the "Confirm" of Embed–Doubt–Confirm
  and the merge. Reward-gated and **precision-first**: a false merge *contaminates*
  evidence (lets one entity's evidence corroborate another) and is hard to reverse,
  and distinct-origin accounting cannot undo it — so the bias is to NOT merge.

  Two distinct risks (decorrelated council):
  - **Inflation** (correlated evidence) is already solved — `merge_nodes` unions
    provenance+origin and recomputes `seen_count = count(DISTINCT origin)`, so
    folding two spellings of ONE source stays one witness.
  - **Contamination** (a FALSE merge) is guarded only by precision: the ER-2 hard
    gate (vector AND lexical) proposes; a **conservative** LLM confirm adjudicates
    (yes only if certain; any doubt / parse failure / model error ⇒ no merge).

  Off by default — `run_pass/1` is the operator/cron unit, like enrichment. The LLM
  is injectable (`:confirm_fun`) so the merge/safety logic is tested deterministically.
  Privacy: only node ids + cosine are logged — never the keys (entity surface forms
  are content).
  """

  alias Swarm.EntityResolution.{Candidates, Vectors}
  alias Swarm.Graph.Store
  alias Swarm.ML.Generation
  alias Swarm.Repo

  require Logger

  @confirm_system ~s(Decide whether two names refer to the SAME real-world entity. ) <>
                    ~s(Answer STRICT JSON only: {"same": true} or {"same": false}. ) <>
                    ~s(Say true ONLY if you are confident they are the same entity; if there ) <>
                    ~s(is any doubt, say false.)

  @typedoc "Summary of one resolution pass."
  @type summary :: %{
          proposed: non_neg_integer(),
          confirmed: non_neg_integer(),
          merged: non_neg_integer()
        }

  @doc """
  Run one bounded soft-match pass: embed entity keys (ER-1) → propose gated pairs
  (ER-2) → for each, confirm (conservative LLM) → on yes, merge. Returns a summary.
  `opts`: `:embed_fun`, `:confirm_fun` (`(pair) -> boolean`), `:model`, plus the
  ER-2 thresholds. Off by default; invoked by an operator/cron.
  """
  @spec run_pass(keyword()) :: summary()
  def run_pass(opts \\ []) do
    cfg = Application.get_env(:swarm, :entity_resolution, [])
    model = Keyword.get(opts, :model) || cfg[:model] || "qwen3:14b"
    confirm = Keyword.get(opts, :confirm_fun, fn pair -> llm_confirm(pair, model) end)

    # Ensure entity identity vectors exist (no-op when all are vec'd).
    _ = Vectors.embed_entities(opts)
    pairs = Candidates.propose(opts)

    Enum.reduce(pairs, %{proposed: length(pairs), confirmed: 0, merged: 0}, fn pair, acc ->
      process_pair(pair, confirm.(pair), model, acc)
    end)
  end

  # One proposed pair: rejected ⇒ unchanged; confirmed ⇒ count + attempt the merge.
  # Every decision is audited (ids/scores/model only — never keys).
  @spec process_pair(Candidates.pair(), boolean(), String.t(), summary()) :: summary()
  defp process_pair(pair, false, model, acc) do
    audit(pair, model, "rejected", nil)
    acc
  end

  defp process_pair(pair, true, model, acc) do
    Logger.info(
      "entity-resolution: confirm node #{pair.a} ↔ node #{pair.b} cos=#{Float.round(pair.cosine, 3)}"
    )

    acc = %{acc | confirmed: acc.confirmed + 1}

    case merge(pair) do
      {:ok, %{result: :merged, into_id: into}} ->
        audit(pair, model, "confirmed_merged", into)
        %{acc | merged: acc.merged + 1}

      _ ->
        audit(pair, model, "confirmed_noop", nil)
        acc
    end
  end

  # Record the decision with NON-SENSITIVE features only (no keys — content). The
  # audit outlives a merged-away node, so it stays inspectable/tunable (council).
  @spec audit(Candidates.pair(), String.t(), String.t(), integer() | nil) :: :ok
  defp audit(pair, model, decision, into_id) do
    Repo.query!(
      "INSERT INTO entity_resolution_audit (left_id, right_id, cosine, lex, model, decision, into_id) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, $7)",
      [pair.a, pair.b, pair.cosine, pair.lex, model, decision, into_id]
    )

    :ok
  end

  @doc """
  Confirm + merge a single proposed pair (the unit `run_pass` drives). Returns the
  `merge_nodes` result on a confident yes, or `:not_confirmed`.
  """
  @spec resolve(Candidates.pair(), keyword()) :: {:ok, map()} | :not_confirmed
  def resolve(pair, opts \\ []) do
    cfg = Application.get_env(:swarm, :entity_resolution, [])
    model = Keyword.get(opts, :model) || cfg[:model] || "qwen3:14b"
    confirm = Keyword.get(opts, :confirm_fun, fn p -> llm_confirm(p, model) end)

    if confirm.(pair), do: merge(pair), else: :not_confirmed
  end

  # Merge the lower-value spelling INTO the canonical one. Canonical = higher graph
  # degree (more connected), ties broken by lower id (earlier). merge_nodes is
  # provenance/origin-preserving and scope-aware (ER-2 only proposes same-scope).
  @spec merge(Candidates.pair()) :: {:ok, map()} | {:error, term()}
  defp merge(%{a: a, b: b, a_key: a_key, b_key: b_key}) do
    {alias_key, into_key} = survivor(a, a_key, b, b_key)
    Store.merge_nodes("entity", alias_key, into_key)
  end

  # → {alias_key, into_key}: the canonical (survivor) is `into_key`.
  @spec survivor(integer(), String.t(), integer(), String.t()) :: {String.t(), String.t()}
  defp survivor(a, a_key, b, b_key) do
    da = degree(a)
    db = degree(b)

    cond do
      da > db -> {b_key, a_key}
      db > da -> {a_key, b_key}
      a <= b -> {b_key, a_key}
      true -> {a_key, b_key}
    end
  end

  @spec degree(integer()) :: non_neg_integer()
  defp degree(node_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM edge WHERE src = $1 OR dst = $1", [node_id])

    n
  end

  # Conservative LLM confirm: any doubt, parse failure, or model error ⇒ false (do
  # NOT merge). Precision over recall — a false merge is the dangerous outcome.
  @spec llm_confirm(Candidates.pair(), String.t()) :: boolean()
  defp llm_confirm(%{a_key: a_key, b_key: b_key}, model) do
    prompt = "A: #{a_key}\nB: #{b_key}\n\nSame entity? JSON:"

    case Generation.generate(model, prompt, json: false, system: @confirm_system) do
      {:ok, raw} -> parse_same(raw)
      {:error, _} -> false
    end
  end

  @spec parse_same(String.t()) :: boolean()
  defp parse_same(raw) do
    json =
      case {:binary.match(raw, "{"), :binary.matches(raw, "}")} do
        {{i, _}, matches} when matches != [] ->
          last = matches |> List.last() |> elem(0)
          :binary.part(raw, i, last - i + 1)

        _ ->
          "{}"
      end

    case Jason.decode(json) do
      {:ok, %{"same" => true}} -> true
      _ -> false
    end
  end
end
