defmodule Swarm.Enrichment.PageTreeProjection do
  @moduledoc """
  Conservative projection from CMS page hierarchy into semantic structure.

  `child_of` remains the source-navigation fact. This module can derive two
  kinds of extra facts from one child page, its parent page title, and the child
  body:

  - document-about pages emit `documents` and `applies_to` from the page node to
    the parent entity.
  - true containment emits `part_of` only between entity nodes, with explicit
    body evidence and a conservative confirm.

  Any ambiguity returns no projected edges.
  """

  alias Swarm.Graph.Store
  alias Swarm.Repo

  @entity_type "entity"
  @document_relations ~w(documents applies_to)
  @max_passage 2_400

  @bucket_parent ~r/(?ix)
    ^\s*(19|20)\d{2}\s*$
    | \b(template|templates|archive|archives|archived|old|deprecated|trash|drafts?)\b
    | \b(index|overview|summary|home|accueil|vue\s+d['’]?ensemble|sommaire)\b
  /

  @positive_part_evidence ~r/(?ix)
    \b(part\s+of|component\s+of|member\s+of|belongs\s+to|included\s+in|contained\s+in)\b
    | \b(is|are|was|were)\s+(a\s+|an\s+)?(component|part|member|subcomponent)\s+of\b
    | \b(consists?\s+of|contains?|includes?|comprises?)\b
    | \bfait\s+partie\s+de\b
    | \bcomposant\s+de\b
  /

  @system """
  You classify one CMS page-tree edge. The tree position is weak evidence: do not
  believe it by itself.

  Output STRICT JSON only:
  {"bucket":"documents|part_of|filing|none","confirm":true|false,"child_entity":"...","parent_entity":"...","evidence":"..."}

  Buckets:
  - documents: the child page is a document/runbook/procedure/troubleshooting page
    about or applying to the parent subject.
  - part_of: the child title names an entity that is semantically a component,
    member, or contained part of the parent entity.
  - filing: the parent is an organizational bucket such as a year, archive,
    templates, index, overview, or loose folder.
  - none: unsure or unsupported.

  For part_of, confirm=true only when the passage itself explicitly states
  containment/componenthood. If there is any doubt, use bucket=none or
  confirm=false. Never infer part_of from page position alone.
  """

  @type bucket :: :documents | :part_of | :filing | :none
  @type decision :: %{
          bucket: bucket(),
          child_entity: String.t() | nil,
          parent_entity: String.t() | nil,
          evidence: String.t() | nil
        }

  @doc "True when a parent title is an organizational filing bucket, not an entity."
  @spec organizational_parent?(term()) :: boolean()
  def organizational_parent?(title) when is_binary(title), do: Regex.match?(@bucket_parent, title)
  def organizational_parent?(_), do: true

  @doc """
  Classify one child page / parent page pair. Returns a fail-closed decision.

  `opts`: `:gen_fun`, `:model`, `:max_passage`.
  """
  @spec classify(String.t(), String.t(), String.t(), keyword()) :: decision()
  def classify(child_title, parent_title, body, opts \\ [])

  def classify(child_title, parent_title, body, opts)
      when is_binary(child_title) and is_binary(parent_title) and is_binary(body) do
    cond do
      blank?(child_title) or blank?(parent_title) ->
        none()

      organizational_parent?(parent_title) ->
        %{none() | bucket: :filing}

      true ->
        gen = Keyword.get(opts, :gen_fun, &Swarm.ML.Generation.generate/3)
        model = Keyword.get(opts, :model) || "qwen3:14b"
        max_passage = Keyword.get(opts, :max_passage, @max_passage)
        passage = String.slice(body, 0, max_passage)

        prompt = """
        CHILD TITLE: #{child_title}
        PARENT TITLE: #{parent_title}
        CHILD BODY:
        #{passage}

        JSON:
        """

        case gen.(model, prompt, json: false, system: @system) do
          {:ok, raw} -> raw |> parse() |> validate(child_title, parent_title, passage)
          {:error, _} -> none()
        end
    end
  end

  def classify(_, _, _, _), do: none()

  @doc """
  Write projected edges for a decision. Returns fresh edge ids.

  The original `child_of` edge is not read or changed here.
  """
  @spec write(map(), decision(), String.t(), keyword()) :: [integer()]
  def write(child_node, decision, provenance, opts \\ [])
      when is_map(child_node) and is_map(decision) and is_binary(provenance) do
    origin = Keyword.get(opts, :origin) || "enrich:page_tree:node:#{child_node.id}"
    lineage = Keyword.get(opts, :lineage)
    reliability = Keyword.get(opts, :reliability, 0.65)

    case decision do
      %{bucket: :documents, parent_entity: parent} when is_binary(parent) ->
        parent_id = Store.upsert_node(@entity_type, entity_key(parent), scope: child_node.scope)

        Enum.flat_map(@document_relations, fn relation ->
          add_edge(
            child_node.id,
            parent_id,
            relation,
            child_node,
            provenance,
            origin,
            lineage,
            reliability
          )
        end)

      %{bucket: :part_of, child_entity: child, parent_entity: parent}
      when is_binary(child) and is_binary(parent) ->
        with {:ok, child_id} <- existing_entity_id(child, child_node.scope),
             {:ok, parent_id} <- existing_entity_id(parent, child_node.scope) do
          add_edge(
            child_id,
            parent_id,
            "part_of",
            child_node,
            provenance,
            origin,
            lineage,
            reliability
          )
        else
          :error -> []
        end

      _ ->
        []
    end
  end

  @spec existing_entity_id(String.t(), String.t()) :: {:ok, integer()} | :error
  defp existing_entity_id(name, scope) do
    case Repo.query!(
           "SELECT id FROM node WHERE type = 'entity' AND key = $1 AND scope = $2",
           [entity_key(name), scope]
         ) do
      %{rows: [[id]]} -> {:ok, id}
      _ -> :error
    end
  end

  @spec add_edge(
          integer(),
          integer(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          String.t() | nil,
          float()
        ) ::
          [integer()]
  defp add_edge(src, dst, relation, child_node, provenance, origin, lineage, reliability) do
    case Store.add_edge(src, dst, relation, provenance,
           scope: child_node.scope,
           origin: origin,
           lineage: lineage,
           reliability: reliability,
           evidence_kind: "derived",
           source_node_id: child_node.id
         ) do
      {:ok, %{id: id}} -> [id]
      {:error, _} -> []
    end
  end

  @spec parse(String.t()) :: map()
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
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  @spec validate(map(), String.t(), String.t(), String.t()) :: decision()
  defp validate(
         %{"bucket" => "documents", "confirm" => true} = m,
         _child_title,
         parent_title,
         passage
       ) do
    parent = clean(Map.get(m, "parent_entity"))
    evidence = clean(Map.get(m, "evidence"))

    if grounded_parent?(parent, parent_title, passage) do
      %{bucket: :documents, child_entity: nil, parent_entity: parent, evidence: evidence}
    else
      none()
    end
  end

  defp validate(
         %{"bucket" => "part_of", "confirm" => true} = m,
         child_title,
         parent_title,
         passage
       ) do
    child = clean(Map.get(m, "child_entity"))
    parent = clean(Map.get(m, "parent_entity"))
    evidence = clean(Map.get(m, "evidence"))

    if not organizational_parent?(parent_title) and
         grounded_child?(child, child_title, passage) and
         grounded_parent?(parent, parent_title, passage) and
         positive_body_evidence?(evidence, passage) and
         entity_key(child) != entity_key(parent) do
      %{bucket: :part_of, child_entity: child, parent_entity: parent, evidence: evidence}
    else
      none()
    end
  end

  defp validate(%{"bucket" => "filing"}, _child_title, _parent_title, _passage),
    do: %{none() | bucket: :filing}

  defp validate(_, _, _, _), do: none()

  @spec grounded_child?(String.t() | nil, String.t(), String.t()) :: boolean()
  defp grounded_child?(entity, child_title, passage),
    do: grounded?(entity, child_title) or grounded?(entity, passage)

  @spec grounded_parent?(String.t() | nil, String.t(), String.t()) :: boolean()
  defp grounded_parent?(entity, parent_title, passage),
    do: grounded?(entity, parent_title) or grounded?(entity, passage)

  @spec positive_body_evidence?(String.t() | nil, String.t()) :: boolean()
  defp positive_body_evidence?(evidence, passage) do
    is_binary(evidence) and evidence != "" and grounded?(evidence, passage) and
      Regex.match?(@positive_part_evidence, evidence)
  end

  @spec grounded?(String.t() | nil, String.t()) :: boolean()
  defp grounded?(nil, _text), do: false
  defp grounded?("", _text), do: false
  defp grounded?(needle, text), do: String.contains?(normalize(text), normalize(needle))

  @spec clean(term()) :: String.t() | nil
  defp clean(s) when is_binary(s) do
    s = s |> :unicode.characters_to_nfc_binary() |> String.replace(~r/\s+/u, " ") |> String.trim()
    if s == "", do: nil, else: String.slice(s, 0, 200)
  end

  defp clean(_), do: nil

  defp blank?(s), do: clean(s) in [nil, ""]

  @spec entity_key(String.t()) :: String.t()
  defp entity_key(s), do: s |> normalize() |> String.slice(0, 200)

  defp normalize(s),
    do:
      s
      |> :unicode.characters_to_nfc_binary()
      |> String.downcase()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

  @spec none() :: decision()
  defp none, do: %{bucket: :none, child_entity: nil, parent_entity: nil, evidence: nil}
end
