defmodule Swarm.Graph.Network do
  @moduledoc """
  Network-map READ view (workspace ADR-17 world-map; substrate written by
  `Swarm.Enrichment.NetworkMap`). Reconstructs the topology skeleton at READ time from the
  namespaced `net:<kind>:<name>` `entity` nodes + their governed relation claim-edges — never a
  reified object (facts stay edges).

  **Provisional by construction** (blackboard council, the "ghost infrastructure" risk): Phase-1
  facts are prose-extracted `hypothesis`-kind edges at low reliability. This view is a discovery
  aid, NOT ground truth — it deliberately offers NO confident affordances (shortest-path,
  blast-radius, security-boundary) until Phase-2 (infra-as-code) evidence exists. Each relation
  carries its `reliability` + `seen_count` so the caller can weigh how well-attested it is.

  Scope-enforced on the entity endpoints AND the edge (`visibility_scope`); refuted edges
  (`reward < 0`) excluded, like every other read path. Network facts are clamped to `group` at
  write, so a `[public]` read never surfaces topology (no-leak).
  """

  alias Swarm.Repo

  @typedoc "A network entity: its namespaced key, derived kind, and display name."
  @type entity :: %{key: String.t(), kind: String.t(), name: String.t()}

  @typedoc "A directed relation between two network entities, with attestation."
  @type relation :: %{
          src: String.t(),
          relation: String.t(),
          dst: String.t(),
          reliability: float(),
          seen_count: integer()
        }

  @doc """
  The network-map skeleton visible at `scopes`: `%{entities: [entity()], relations: [relation()]}`.
  Relations exclude the `is_a` typing edges (those are folded into each entity's `kind`). Empty
  when nothing is in scope. Ordered for stable rendering (entities by key; relations by
  reliability desc then key).
  """
  @spec map([String.t()]) :: %{entities: [entity()], relations: [relation()]}
  def map(scopes) when is_list(scopes) do
    %{entities: entities(scopes), relations: relations(scopes)}
  end

  def map(_), do: %{entities: [], relations: []}

  @doc "In-scope network entities (namespaced `net:<kind>:<name>` nodes)."
  @spec entities([String.t()]) :: [entity()]
  def entities([]), do: []

  def entities(scopes) when is_list(scopes) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT n.key
          FROM node n
         WHERE n.type = 'entity' AND n.scope = ANY($1) AND n.key LIKE 'net:%'
         ORDER BY n.key
        """,
        [scopes]
      )

    Enum.map(rows, fn [key] -> decode_key(key) end)
  end

  @doc "In-scope relation edges between network entities (excluding `is_a` typing edges)."
  @spec relations([String.t()]) :: [relation()]
  def relations([]), do: []

  def relations(scopes) when is_list(scopes) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT s.key, e.type, d.key, e.reliability, e.seen_count
          FROM edge e
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE e.type <> 'is_a' AND e.reward >= 0 AND e.visibility_scope = ANY($1)
           AND s.key LIKE 'net:%' AND d.key LIKE 'net:%'
           AND s.scope = ANY($1) AND d.scope = ANY($1)
         ORDER BY e.reliability DESC, s.key, e.type, d.key
        """,
        [scopes]
      )

    Enum.map(rows, fn [src, type, dst, rel, seen] ->
      %{
        src: strip_ns(src),
        relation: type,
        dst: strip_ns(dst),
        reliability: rel,
        seen_count: seen
      }
    end)
  end

  # `net:<kind>:<name>` → %{key, kind, name}. A malformed key degrades gracefully to kind "entity".
  @spec decode_key(String.t()) :: entity()
  defp decode_key(key) do
    case String.split(key, ":", parts: 3) do
      ["net", kind, name] -> %{key: key, kind: kind, name: name}
      _ -> %{key: key, kind: "entity", name: strip_ns(key)}
    end
  end

  # `net:<kind>:<name>` → "<kind>/<name>" for compact rendering (or the raw key if malformed).
  @spec strip_ns(String.t()) :: String.t()
  defp strip_ns(key) do
    case String.split(key, ":", parts: 3) do
      ["net", kind, name] -> kind <> "/" <> name
      _ -> key
    end
  end
end
