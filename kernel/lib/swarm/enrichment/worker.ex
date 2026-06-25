defmodule Swarm.Enrichment.Worker do
  @moduledoc """
  Reward-gated enrichment (workspace ADR-13 / EOS-4): extract subject-predicate-
  object claims from a node's stored text and write them as **typed assertions**
  onto the graph. This is the cost-asymmetry pillar in the flesh — an LLM call of
  ~120 s/source — so it is rare and deliberate, never the continuous default
  (scheduling is EW-4/EW-5; this module is extraction + write, gated by the
  watermark).

  What it writes (model B, EW-1): each triple becomes an edge between the subject
  and object **entity** nodes, carrying `evidence_kind: "claim"` — the assertion is
  the claim, the entities are just things. `origin` is the SOURCE node's identity
  (one document = one evidential origin for all the claims it makes), so N claims
  from one source never corroborate as N independent witnesses, and re-running over
  the same source neither duplicates (same provenance) nor over-corroborates (same
  origin). The LLM model is injectable (`:gen_fun`) so the write/parse logic is
  tested deterministically without a 120 s round-trip.

  **Watermark (EOS-4 §1a):** before extracting, a content-sensitive watermark is
  consulted — an unchanged, already-`fresh` node is skipped (zero LLM calls); a
  changed body / bumped policy / bumped model re-enriches. On a content-change
  re-enrich the prior claims are **reconciled** (stale triples dropped, surviving
  ones kept) so enrichment is not append-only memory for edited documents.

  **Zone / convergence guard (EOS-4 §1c):** the worker NEVER enriches an
  LLM-generated zone (`claim`/`hypothesis`/`derived`) — feeding the worker its own
  output is the unbounded worker→graph→worker loop. The generation-counter half is
  EW-5.

  Privacy: claims inherit the source node's scope (group-scope content stays
  group); the model is LOCAL (config). Enrichment output IS content — never logged.
  """

  alias Swarm.Enrichment.Watermark
  alias Swarm.Graph.Store
  alias Swarm.Ingest.Content
  alias Swarm.ML.Generation
  alias Swarm.Repo

  require Logger

  @system "You extract factual claims from a passage as subject-predicate-object triples. " <>
            "Extract ONLY claims explicitly stated in the passage. The predicate is a short " <>
            "lowercase snake_case verb phrase (e.g. located_in, founded_by, is_a, part_of). " <>
            "Keep subject/object short noun phrases. Output STRICT JSON only, no prose: " <>
            "{\"claims\":[{\"s\":\"subject\",\"p\":\"predicate\",\"o\":\"object\"}]}. At most 8 claims."

  @generated_kinds ~w(claim hypothesis derived)

  @typedoc "Outcome of one enrichment: how many triples were extracted and how many became edges."
  @type result :: %{claims: non_neg_integer(), edges: non_neg_integer()}

  @doc """
  Enrich one node: extract S-P-O claims from its stored body and write them as
  `claim`-kind assertion edges between entity nodes.

  `opts`:
  - `:gen_fun` — `(model, prompt, keyword) -> {:ok, raw} | {:error, term}`;
    defaults to the real `Swarm.ML.Generation.generate/3`.
  - `:model` — overrides the configured local enrichment model.
  - `:force` — bypass the watermark (re-extract even if fresh).
  - `:generation` — the scheduler's pass counter, recorded in the watermark
    (defaults to the node's current generation). Gen-N output is only eligible
    input in gen-N+1 (the scheduler snapshots candidates per pass), so the
    worker→graph→worker loop is generation-bounded.

  Returns `{:ok, result}`, `{:skip, reason}` (`:generated_zone` / `:no_body` /
  `:watermarked`), or a typed `{:error, reason}` (fail-loud — a generation failure
  is an error, not "0 claims").
  """
  @spec enrich(integer(), keyword()) :: {:ok, result()} | {:skip, atom()} | {:error, term()}
  def enrich(node_id, opts \\ []) when is_integer(node_id) do
    case load(node_id) do
      nil ->
        {:error, :no_such_node}

      %{kind: kind} when kind in @generated_kinds ->
        {:skip, :generated_zone}

      node ->
        case body(node_id) do
          b when is_binary(b) and b != "" -> gate(node, b, opts)
          _ -> {:skip, :no_body}
        end
    end
  end

  # Watermark gate: skip an unchanged, fresh node (no LLM call); otherwise run.
  @spec gate(map(), String.t(), keyword()) :: {:ok, result()} | {:skip, atom()} | {:error, term()}
  defp gate(node, body, opts) do
    cfg = Application.get_env(:swarm, :enrichment, [])
    model = Keyword.get(opts, :model) || cfg[:model] || "qwen3:14b"
    policy = cfg[:policy_version] || 1
    hash = Content.body_hash(body)

    if Keyword.get(opts, :force, false) or Watermark.needs?(node.id, hash, policy, model) do
      run(node, body, %{hash: hash, policy: policy, model: model}, opts)
    else
      {:skip, :watermarked}
    end
  end

  @spec run(map(), String.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  defp run(node, body, %{hash: hash, policy: policy, model: model}, opts) do
    max_passage = Application.get_env(:swarm, :enrichment, [])[:max_passage] || 2_400
    gen = Keyword.get(opts, :gen_fun, &Generation.generate/3)
    prompt = "PASSAGE:\n" <> String.slice(body, 0, max_passage) <> "\n\nJSON:"
    gen_ct = Keyword.get(opts, :generation) || Watermark.generation(node.id)

    # The model call is OUTSIDE any transaction — it is slow (~120 s) and must not
    # hold a DB connection/lock open.
    stamp = fn state ->
      %{
        content_hash: hash,
        policy_version: policy,
        model: model,
        generation: gen_ct,
        state: state
      }
    end

    case gen.(model, prompt, json: false, system: @system) do
      {:ok, raw} ->
        claims = parse(raw)

        # A malformed triple is dropped and the run continues; an unexpected WRITE
        # failure aborts the run (council, codex): otherwise `kept` would be
        # incomplete and reconcile could delete a still-live prior claim. On abort
        # we skip reconcile + the fresh watermark, and record `error` to retry.
        case write_claims(node, claims) do
          {:ok, edge_ids} ->
            reconcile(node.id, edge_ids)
            Watermark.record(node.id, stamp.("fresh"))
            {:ok, %{claims: length(claims), edges: length(edge_ids)}}

          {:error, reason} ->
            Watermark.record(node.id, stamp.("error"))
            {:error, {:write_failed, reason}}
        end

      {:error, reason} ->
        # Fail loud (ADR-7), and record an `error` watermark so the node is retried
        # (needs?/4 treats a non-fresh state as needing re-enrichment).
        Watermark.record(node.id, stamp.("error"))
        {:error, {:generation_failed, reason}}
    end
  end

  # Write each triple as a claim assertion. One source = one evidential `origin`
  # (claims don't self-corroborate); one run = one `provenance` (a re-run dedups
  # per edge). A malformed triple is `{:skip, _}` — dropped with a logged reason
  # (no silent drop), run continues. A genuine write failure is `{:error, _}` and
  # HALTS the run (returns `{:error, reason}`) so reconcile never sees an
  # incomplete set. Returns `{:ok, edge_ids}` or `{:error, reason}`.
  @spec write_claims(map(), [map()]) :: {:ok, [integer()]} | {:error, term()}
  defp write_claims(node, claims) do
    origin = origin(node.id)
    provenance = provenance(node.id)
    reliability = Application.get_env(:swarm, :enrichment, [])[:claim_reliability] || 0.5

    Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, ids} ->
      case write_one(node, claim, origin, provenance, reliability) do
        {:ok, edge_id} ->
          {:cont, {:ok, [edge_id | ids]}}

        {:skip, reason} ->
          Logger.debug("enrichment: dropped triple from node #{node.id}: #{inspect(reason)}")
          {:cont, {:ok, ids}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec write_one(map(), map(), String.t(), String.t(), float()) ::
          {:ok, integer()} | {:skip, term()} | {:error, term()}
  defp write_one(node, %{s: s, p: p, o: o}, origin, provenance, reliability) do
    pred = predicate(p)
    subj_key = entity_key(s)
    obj_key = entity_key(o)

    cond do
      pred == "" ->
        {:skip, :bad_predicate}

      subj_key == "" or obj_key == "" ->
        {:skip, :blank_entity}

      true ->
        subj = Store.upsert_node("entity", subj_key, scope: node.scope)
        obj = Store.upsert_node("entity", obj_key, scope: node.scope)

        case Store.add_edge(subj, obj, pred, provenance,
               scope: node.scope,
               origin: origin,
               evidence_kind: "claim",
               reliability: reliability
             ) do
          {:ok, %{id: edge_id}} -> {:ok, edge_id}
          # A well-formed claim that failed to PERSIST → abort (not a silent drop).
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Stale-claim replacement (EW-2 council, codex): on a content-change re-enrich,
  # drop THIS source's prior assertions that are not in the new extraction. Remove
  # only this source's provenance row (an edge still attested by another source
  # survives, with seen_count recomputed); delete an edge only when it has no
  # provenance left. Scoped to this source's stale edges (indexed), one transaction.
  @spec reconcile(integer(), [integer()]) :: :ok
  defp reconcile(node_id, kept_edge_ids) do
    prov = provenance(node_id)

    %{rows: stale_rows} =
      Repo.query!(
        "SELECT edge_id FROM edge_provenance WHERE provenance = $1 AND edge_id <> ALL($2::bigint[])",
        [prov, kept_edge_ids]
      )

    stale = Enum.map(stale_rows, fn [id] -> id end)

    if stale != [] do
      Repo.transaction(fn ->
        # Lock the stale edge rows for the txn (defense-in-depth, council/gemma):
        # serialise against a concurrent writer touching the same edges, so the
        # prune → orphan-delete → recompute sequence sees a stable set. (Enrichment
        # is single-threaded per the scheduler, so this is belt-and-suspenders.)
        Repo.query!("SELECT id FROM edge WHERE id = ANY($1::bigint[]) FOR UPDATE", [stale])

        Repo.query!(
          "DELETE FROM edge_provenance WHERE provenance = $1 AND edge_id = ANY($2::bigint[])",
          [prov, stale]
        )

        # Edges with no remaining provenance are orphaned → delete; the rest just
        # lost a source, so recompute their distinct-origin seen_count.
        Repo.query!(
          "DELETE FROM edge e WHERE e.id = ANY($1::bigint[]) " <>
            "AND NOT EXISTS (SELECT 1 FROM edge_provenance ep WHERE ep.edge_id = e.id)",
          [stale]
        )

        Repo.query!(
          "UPDATE edge e SET seen_count = " <>
            "(SELECT count(DISTINCT coalesce(origin, provenance)) FROM edge_provenance ep WHERE ep.edge_id = e.id) " <>
            "WHERE e.id = ANY($1::bigint[])",
          [stale]
        )
      end)
    end

    :ok
  end

  @spec origin(integer()) :: String.t()
  defp origin(node_id), do: "enrich:origin:node:#{node_id}"

  @spec provenance(integer()) :: String.t()
  defp provenance(node_id), do: "enrich:node:#{node_id}"

  # Robust parse (spike lesson): slice first '{' .. last '}' so stray prose/think
  # tokens don't break decode; keep only well-formed string triples.
  @spec parse(String.t()) :: [map()]
  defp parse(raw) do
    json =
      case {:binary.match(raw, "{"), :binary.matches(raw, "}")} do
        {{a, _}, matches} when matches != [] ->
          last = matches |> List.last() |> elem(0)
          :binary.part(raw, a, last - a + 1)

        _ ->
          raw
      end

    case Jason.decode(json) do
      {:ok, %{"claims" => cs}} when is_list(cs) ->
        Enum.flat_map(cs, fn
          %{"s" => s, "p" => p, "o" => o} when is_binary(s) and is_binary(p) and is_binary(o) ->
            [%{s: s, p: p, o: o}]

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  # Normalize a predicate to a valid relation type (`^[a-z][a-z0-9_]*$`); "" if it
  # cannot be made one (e.g. leading digit, empty) → the triple is dropped.
  @spec predicate(String.t()) :: String.t()
  defp predicate(p) do
    norm =
      p
      |> :unicode.characters_to_nfc_binary()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")
      |> String.slice(0, 50)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, norm), do: norm, else: ""
  end

  # Normalize an entity surface form to a node key (NFC, collapsed whitespace,
  # trimmed, bounded). No lossy ASCII folding (keeps Cyrillic/CJK identifiers).
  @spec entity_key(String.t()) :: String.t()
  defp entity_key(s) do
    s
    |> :unicode.characters_to_nfc_binary()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 200)
  end

  @spec load(integer()) :: %{id: integer(), kind: String.t(), scope: String.t()} | nil
  defp load(node_id) do
    case Repo.query!("SELECT id, kind, scope FROM node WHERE id = $1", [node_id]) do
      %{rows: [[id, kind, scope]]} -> %{id: id, kind: kind, scope: scope}
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
