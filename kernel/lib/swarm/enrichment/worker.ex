defmodule Swarm.Enrichment.Worker do
  @moduledoc """
  Reward-gated enrichment (workspace ADR-13 / EOS-4): extract subject-predicate-
  object claims from a node's stored text and write them as **typed assertions**
  onto the graph. This is the cost-asymmetry pillar in the flesh — an LLM call of
  ~120 s/source — so it is rare and deliberate, never the continuous default
  (scheduling is EW-4/EW-5; this module is the extraction + write step).

  What it writes (model B, EW-1): each triple becomes an edge between the subject
  and object **entity** nodes, carrying `evidence_kind: "claim"` — the assertion is
  the claim, the entities are just things. `origin` is the SOURCE node's identity
  (one document = one evidential origin for all the claims it makes), so N claims
  from one source never corroborate as N independent witnesses, and re-running over
  the same source neither duplicates (same provenance) nor over-corroborates (same
  origin). The LLM model is injectable (`:gen_fun`) so the write/parse logic is
  tested deterministically without a 120 s round-trip.

  **Zone / convergence guard (EOS-4 §1c):** the worker NEVER enriches an
  LLM-generated zone (`claim`/`hypothesis`/`derived`) — feeding the worker its own
  output is the unbounded worker→graph→worker loop. It enriches only external
  zones (`observation`/article). The generation-counter half of the guard is EW-5.

  Privacy: claims inherit the source node's scope (group-scope content stays
  group); the model is LOCAL (config). Enrichment output IS content — never logged.
  """

  alias Swarm.Graph.Store
  alias Swarm.ML.Generation
  alias Swarm.Repo

  require Logger

  @system "You extract factual claims from a passage as subject-predicate-object triples. " <>
            "Extract ONLY claims explicitly stated in the passage. The predicate is a short " <>
            "lowercase snake_case verb phrase (e.g. located_in, founded_by, is_a, part_of). " <>
            "Keep subject/object short noun phrases. Output STRICT JSON only, no prose: " <>
            "{\"claims\":[{\"s\":\"subject\",\"p\":\"predicate\",\"o\":\"object\"}]}. At most 8 claims."

  # LLM-generated zones — enriching one feeds the worker its own output (the
  # convergence guard; EOS-4 §1c). `node.kind` says what the node IS.
  @generated_kinds ~w(claim hypothesis derived)

  @typedoc "Outcome of one enrichment: how many triples were extracted and how many became edges."
  @type result :: %{claims: non_neg_integer(), edges: non_neg_integer()}

  @doc """
  Enrich one node: extract S-P-O claims from its stored body and write them as
  `claim`-kind assertion edges between entity nodes.

  `opts`:
  - `:gen_fun` — the generation function `(model, prompt, keyword) -> {:ok, raw} |
    {:error, term}`; defaults to the real `Swarm.ML.Generation.generate/3`.
  - `:model` — overrides the configured local enrichment model.

  Returns `{:ok, result}`, `{:skip, reason}` (zone guard / no body), or a typed
  `{:error, reason}` (fail-loud — a generation failure is an error, not "0 claims").
  """
  @spec enrich(integer(), keyword()) :: {:ok, result()} | {:skip, atom()} | {:error, term()}
  def enrich(node_id, opts \\ []) when is_integer(node_id) do
    case load(node_id) do
      nil ->
        {:error, :no_such_node}

      %{kind: kind} when kind in @generated_kinds ->
        # Convergence guard: never enrich the worker's own output zone.
        {:skip, :generated_zone}

      node ->
        case body(node_id) do
          b when is_binary(b) and b != "" -> extract_and_write(node, b, opts)
          _ -> {:skip, :no_body}
        end
    end
  end

  @spec extract_and_write(map(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defp extract_and_write(node, body, opts) do
    cfg = Application.get_env(:swarm, :enrichment, [])
    model = Keyword.get(opts, :model) || cfg[:model] || "qwen3:14b"
    max_passage = cfg[:max_passage] || 2_400
    gen = Keyword.get(opts, :gen_fun, &Generation.generate/3)

    prompt = "PASSAGE:\n" <> String.slice(body, 0, max_passage) <> "\n\nJSON:"

    case gen.(model, prompt, json: false, system: @system) do
      {:ok, raw} ->
        claims = parse(raw)
        {:ok, %{claims: length(claims), edges: write_claims(node, claims)}}

      {:error, reason} ->
        # Fail loud (ADR-7): a model/transport failure is an ERROR, distinct from
        # "the passage stated no claims" (which is a successful run with 0 claims).
        {:error, {:generation_failed, reason}}
    end
  end

  # Write each triple as a claim assertion. One source = one evidential `origin`
  # (so its claims don't self-corroborate); one enrichment run = one `provenance`
  # (so a re-run dedups per edge). Entities are `observation` things; the EDGE
  # carries `evidence_kind: "claim"` (EW-1). A malformed triple is dropped with a
  # logged reason (no silent drop), never crashing the run.
  @spec write_claims(map(), [map()]) :: non_neg_integer()
  defp write_claims(node, claims) do
    origin = "enrich:origin:node:#{node.id}"
    provenance = "enrich:node:#{node.id}"
    reliability = Application.get_env(:swarm, :enrichment, [])[:claim_reliability] || 0.5

    Enum.reduce(claims, 0, fn claim, acc ->
      case write_one(node, claim, origin, provenance, reliability) do
        :ok ->
          acc + 1

        {:dropped, reason} ->
          Logger.debug("enrichment: dropped triple from node #{node.id}: #{inspect(reason)}")
          acc
      end
    end)
  end

  @spec write_one(map(), map(), String.t(), String.t(), float()) :: :ok | {:dropped, term()}
  defp write_one(node, %{s: s, p: p, o: o}, origin, provenance, reliability) do
    pred = predicate(p)
    subj_key = entity_key(s)
    obj_key = entity_key(o)

    cond do
      pred == "" ->
        {:dropped, :bad_predicate}

      subj_key == "" or obj_key == "" ->
        {:dropped, :blank_entity}

      true ->
        subj = Store.upsert_node("entity", subj_key, scope: node.scope)
        obj = Store.upsert_node("entity", obj_key, scope: node.scope)

        case Store.add_edge(subj, obj, pred, provenance,
               scope: node.scope,
               origin: origin,
               evidence_kind: "claim",
               reliability: reliability
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:dropped, reason}
        end
    end
  end

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
