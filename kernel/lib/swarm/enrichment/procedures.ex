defmodule Swarm.Enrichment.Procedures do
  @moduledoc """
  Procedure extraction (workspace ADR-17 #2 — blackboard
  `board/research/procedure-extraction-blackboard.md`). A SEPARATE, heuristic-gated pass over a
  source body: when the text looks procedural, a conservative LLM extracts ordered procedures
  and this writes them as the tier-gate's substrate — a procedure `entity` node + ordered
  `has_step` edges to `step` nodes (each carrying an integer `step_ordinal`, `origin`,
  `provenance`, `source_node_id`, `evidence_kind="claim"`), so `Swarm.Graph.Procedure.steps/3`
  and the tier-gate's `:procedure` path finally bite.

  Why a separate pass (council, both families): procedure extraction needs sequential/ordered
  attention, different from broad S-P-O recall — folding degrades both. It is GATED behind a
  cheap heuristic (`procedural?/1`) so non-procedural sources never pay the 2nd LLM call.

  Why `step` is its own node TYPE (not `concept`): steps are isolated, non-fungible imperative
  fragments; in `concept` space synonymy + aggregation would merge "restart the server" across
  unrelated procedures and corrupt the graph.

  Steps are claim-EDGES, not a stored JSON blob (ADR-17 §1 no-reification): each step keeps its
  own provenance + reliability + reversibility, and the read is one indexed JOIN. **Reorder
  safety:** `step_ordinal` is set on first insert (upsert no-ops), so a genuine reorder would
  keep a stale ordinal — `write/3` therefore CLEARS this source's prior `has_step` edges for a
  procedure, then inserts fresh with the new ordinals (delete-then-insert per source). This is
  correct when THIS source is the sole attester (the common case). The multi-source
  divergent-order case stays substrate residual #3 (step_ordinal is per-edge, not per-origin) —
  and is safe: the tier-gate escalates on `>1` procedure variant (`:ambiguous_variants`) rather
  than serve a possibly-wrong order.

  Conservative by design (steps mislead an operator mid-task): only explicitly-ordered steps,
  near-verbatim to the body (substring-validated), ≥2 steps, capped. The tier-gate's Stage-2
  entailment veto is the final guard against a wrong/incomplete served procedure.
  """

  alias Swarm.Graph.Store
  alias Swarm.ML.Generation
  alias Swarm.Repo

  require Logger

  @step_type "step"
  @proc_type "entity"
  @max_procedures 3
  @max_steps 12
  @min_steps 2

  # Cheap procedural-signal gate (no LLM). A source pays the 2nd LLM pass ONLY if its body
  # shows ordered structure — false negatives are acceptable, a false procedure is worse.
  @signals ~r/(?im)(^\s*\d+[.)]\s|\bstep\s*\d|\b(first|then|next|finally|afterwards?)\b|\bhow\s+to\b|\b(runbook|playbook|procedure)\b|^\s*[-*]\s+.*\n\s*[-*]\s)/

  @system "You extract step-by-step PROCEDURES from a passage. A procedure is an explicitly " <>
            "ORDERED list of actions to accomplish a task. Extract ONLY procedures whose steps " <>
            "are explicitly stated and ordered in the passage — never infer or invent steps, " <>
            "never use outside knowledge. Each step's text must be copied (near-verbatim) from " <>
            "the passage. Give each procedure a short imperative NAME (e.g. \"reset LDAP " <>
            "password\"). Output STRICT JSON only, no prose: " <>
            ~s|{"procedures":[{"name":"...","steps":["step one","step two"]}]}. | <>
            "Omit anything not an explicit ordered procedure. At most 3 procedures."

  @doc "Does `body` show procedural signals worth a (2nd) LLM extraction pass?"
  @spec procedural?(String.t()) :: boolean()
  def procedural?(body) when is_binary(body), do: Regex.match?(@signals, body)
  def procedural?(_), do: false

  @typedoc "One extracted procedure: an imperative name + its ordered step texts."
  @type procedure :: %{name: String.t(), steps: [String.t()]}

  @doc """
  Extract procedures from `body` (only if `procedural?/1`). `opts`: `:gen_fun`, `:model`,
  `:max_passage`. Returns the validated `procedure()` list (possibly empty). Pure w.r.t. the
  graph — writing is `write/3`.
  """
  @spec extract(String.t(), keyword()) :: [procedure()]
  def extract(body, opts \\ []) when is_binary(body) do
    if procedural?(body) do
      gen = Keyword.get(opts, :gen_fun, &Generation.generate/3)
      model = Keyword.get(opts, :model) || "qwen3:14b"
      max_passage = Keyword.get(opts, :max_passage, 2_400)
      passage = String.slice(body, 0, max_passage)
      prompt = "PASSAGE:\n" <> passage <> "\n\nJSON:"

      case gen.(model, prompt, json: false, system: @system) do
        {:ok, raw} ->
          raw
          |> parse()
          |> Enum.map(&validate(&1, passage))
          |> Enum.reject(&is_nil/1)
          |> Enum.take(@max_procedures)

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  @doc """
  Write extracted `procedures` for source `node` as procedure-entity + ordered `has_step`→step
  edges. **Reorder-safe:** clears this source's prior `has_step` edges for each procedure, then
  inserts fresh with new ordinals. Returns the fresh `has_step` edge ids (the caller folds them
  into the enrichment `reconcile` kept-set so they are not re-deleted). Scope inherits the
  source node's scope (no-leak).
  """
  @spec write(map(), [procedure()], String.t(), String.t() | nil) :: [integer()]
  def write(node, procedures, provenance, lineage \\ nil) do
    origin = "enrich:origin:node:#{node.id}"

    Enum.flat_map(procedures, fn %{name: name, steps: steps} ->
      proc = Store.upsert_node(@proc_type, name, scope: node.scope)
      clear_source_steps(proc, provenance)

      steps
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {text, ordinal} ->
        write_step(proc, text, ordinal, node, origin, provenance, lineage)
      end)
    end)
  end

  # Insert ONE fresh has_step edge (proc → step node), returning [edge_id] or [] on write error.
  @spec write_step(integer(), String.t(), pos_integer(), map(), String.t(), String.t(), String.t() | nil) ::
          [integer()]
  defp write_step(proc, text, ordinal, node, origin, provenance, lineage) do
    step = Store.upsert_node(@step_type, text, scope: node.scope)

    case Store.add_edge(proc, step, "has_step", provenance,
           scope: node.scope,
           origin: origin,
           lineage: lineage,
           evidence_kind: "claim",
           step_ordinal: ordinal,
           source_node_id: node.id
         ) do
      {:ok, %{id: id}} -> [id]
      {:error, _} -> []
    end
  end

  # Delete THIS source's has_step edges for `proc` so a reorder re-inserts fresh ordinals
  # (step_ordinal is set on first insert). Removes only this source's provenance; an edge still
  # attested by another source survives (its seen_count recomputed), mirroring reconcile.
  @spec clear_source_steps(integer(), String.t()) :: :ok
  defp clear_source_steps(proc, provenance) do
    %{rows: rows} =
      Repo.query!(
        "SELECT e.id FROM edge e JOIN edge_provenance ep ON ep.edge_id = e.id " <>
          "WHERE e.src = $1 AND e.type = 'has_step' AND ep.provenance = $2 ORDER BY e.id",
        [proc, provenance]
      )

    ids = Enum.map(rows, fn [id] -> id end)

    if ids != [] do
      Repo.query!(
        "DELETE FROM edge_provenance WHERE edge_id = ANY($1::bigint[]) AND provenance = $2",
        [
          ids,
          provenance
        ]
      )

      Repo.query!(
        "DELETE FROM edge e WHERE e.id = ANY($1::bigint[]) " <>
          "AND NOT EXISTS (SELECT 1 FROM edge_provenance ep WHERE ep.edge_id = e.id)",
        [ids]
      )

      Repo.query!(
        "UPDATE edge e SET seen_count = " <>
          "(SELECT count(DISTINCT coalesce(lineage, origin, provenance)) FROM edge_provenance ep WHERE ep.edge_id = e.id) " <>
          "WHERE e.id = ANY($1::bigint[])",
        [ids]
      )
    end

    :ok
  end

  # --- parse + validate ------------------------------------------------------

  @spec parse(String.t()) :: [map()]
  defp parse(raw) do
    json = slice_json(raw)

    case Jason.decode(json) do
      {:ok, %{"procedures" => ps}} when is_list(ps) -> ps
      _ -> []
    end
  end

  # A procedure is kept ONLY if: it has a non-blank name, ≥@min_steps ordered steps (capped at
  # @max_steps), and every step is near-verbatim present in the source passage (guards against
  # invented steps). Otherwise dropped. Also bounded to @max_procedures.
  @spec validate(map(), String.t()) :: procedure() | nil
  defp validate(%{"name" => name, "steps" => steps}, passage)
       when is_binary(name) and is_list(steps) do
    trimmed = String.trim(name)

    clean =
      steps |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    grounded = Enum.filter(clean, &grounded?(&1, passage))

    if trimmed != "" and length(grounded) >= @min_steps do
      %{name: trimmed, steps: Enum.take(grounded, @max_steps)}
    else
      nil
    end
  end

  defp validate(_, _), do: nil

  # A step is grounded if a normalized form of it is a substring of the normalized passage —
  # cheap protection against the model inventing steps not in the source (council: verbatim).
  @spec grounded?(String.t(), String.t()) :: boolean()
  defp grounded?(step, passage) do
    String.contains?(normalize(passage), normalize(step))
  end

  defp normalize(s), do: s |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Take the outermost {...} span (stray think/prose tokens don't break decode) — same robust
  # slice the claim parser uses.
  @spec slice_json(String.t()) :: String.t()
  defp slice_json(raw) do
    case {:binary.match(raw, "{"), :binary.matches(raw, "}")} do
      {{a, _}, matches} when matches != [] ->
        last = matches |> List.last() |> elem(0)
        :binary.part(raw, a, last - a + 1)

      _ ->
        raw
    end
  end

  @doc false
  def max_procedures, do: @max_procedures
end
