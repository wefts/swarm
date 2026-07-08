defmodule Swarm.Enrichment.NetworkMap do
  @moduledoc """
  Network-map skeleton extraction (workspace ADR-17 world-map; blackboard
  `board/research/network-map-blackboard.md`, council codex + gemini, strong convergence). A
  SEPARATE heuristic-gated pass (sibling of `Swarm.Enrichment.Procedures`): when a source body
  shows network-topology signals, a conservative LLM extracts MACRO topology facts and this
  writes them as the network-map view's substrate — typed `entity` nodes + typed relation
  claim-edges, no reification (ADR-17 §1).

  ## Phase 1 (this module) vs Phase 2 (deferred)
  This is the **Phase-1 SKELETON from prose**: partial, provisional, low-reliability. The
  **authoritative** topology (exact IPs, CIDRs, firewall rules) comes later from infra-as-code
  (`Phase-2`, a repo-parsing connector) at high reliability — so Phase-1 deliberately REFUSES
  exact addresses/CIDRs/firewall-rules (both council families) and emits at a low reliability
  band so Phase-2 wins aggregation WITHOUT deletion.

  ## Design (blackboard decisions)
  - **Typing = Option C, namespaced.** Node types are a closed kernel vocabulary — rather than
    bump it, network things are plain `entity` nodes keyed `net:<kind>:<canonical>` (the prefix
    prevents the aggregation collision a bare `entity` "core" switch vs "core" project would
    cause), each with an `is_a` edge to a `concept:<kind>` marker (queryable, provenance-bearing
    type — NOT smuggled into a name or JSON).
  - **Governed relation vocabulary** (closed by DISCIPLINE — codex's top anti-pattern is open
    relations becoming an accidental schema via near-duplicates): see `@relations`. `behind_firewall`
    is rejected in favour of `protected_by` (perspective-independent).
  - **Symmetric relations** (`connects_site`, `alias_of`) emit TWO directed claim-edges with
    shared provenance — A-claims-peers-B is a distinct evidential fact from B's; the read view
    treats them undirected.
  - **Conservative** (a wrong network edge served with confidence is dangerous): macro-only;
    endpoint names verbatim-grounded in the passage; explicit present-tense facts with NAMED
    endpoints only — no implied/aspirational/undated-historical/inferred/multi-hop.
  - **Lazy canonicalization** (both families; eager merge is a destructive anti-pattern):
    hostname/FQDN/IP stay DISTINCT nodes; an `alias_of` edge is emitted only when a source states
    the identity explicitly; folding is a read-time view concern. We deliberately do NOT use the
    eager `node_alias` table for network.
  - **No-leak:** network nodes/edges inherit the source node's scope (per-source); derived facts
    never widen past their anchor.

  ## Residual (carded, not built here)
  **Ghost infrastructure** (both families, the single biggest risk): a claim-graph grows
  monotonically — Phase-2 IaC adds current infra but never REFUTES a decommissioned host prose
  still asserts. The `hypothesis` evidence_kind + low reliability is the hook for a future
  TTL/time-decay on unrefreshed network hypotheses; the view stays provisional-labelled (no
  shortest-path/blast-radius affordances) until Phase-2 evidence exists.
  """

  alias Swarm.Graph.Store
  alias Swarm.ML.Generation

  require Logger

  @entity_type "entity"
  @marker_type "concept"
  @reliability 0.35
  @evidence_kind "hypothesis"
  @max_facts 24
  @max_passage 2_400

  # The governed network-entity kinds (Phase-1 macro). Each becomes an `is_a` edge to a
  # `concept:<kind>` marker. Closed by discipline, not by the (node-type) contract.
  @kinds ~w(host subnet site gateway firewall tunnel cluster service vlan address)

  # The governed Phase-1 relation vocabulary (macro-topology only). `is_a` is generated from a
  # fact's endpoint kinds, never asked of the model. `contains` subsumes in_subnet at macro
  # level; exact-address relations (has_address/resolves_to/CIDR identity) are DEFERRED to Phase-2.
  @relations ~w(contains hosted_on routes_via egresses_via connects_site terminates_at protected_by alias_of carries has_address)
  # Symmetric relations: emit both directions with shared provenance (evidential, both families).
  @symmetric ~w(connects_site alias_of)

  # Cheap network-signal gate (no LLM): a source pays the 2nd LLM pass ONLY if its body shows
  # topology vocabulary or address/hostname shapes. False negatives are acceptable; a false
  # network edge is worse. Address SHAPES are only a gate signal here — Phase-1 does not extract
  # exact addresses as facts.
  @signals ~r/(?ix)
      \b(firewall|gateway|subnet|vlan|ipsec|vpn|tunnel|cluster|ingress|egress|
         routes?|routing|peers?\s+with|hosted\s+on|bastion|dmz|uplink|
         metallb|kubespray|fortigate|topology|networks?)\b
    | \b\d{1,3}(\.\d{1,3}){3}\b                         # an IPv4 shape
    | \b\d{1,3}(\.\d{1,3}){3}\/\d{1,2}\b                # a CIDR shape
    | \b[a-z0-9][a-z0-9-]*\.(intranet|corp|local|lan)\b # an internal FQDN shape
    /

  # A bare IP or CIDR is NOT a valid Phase-1 ENTITY name (macro-only — addresses wait for Phase-2).
  @address_shape ~r/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/

  # Relation↔endpoint-kind signatures (measured hardening, 2026-07-06 sequential re-measure): each
  # governed relation only makes sense between certain kinds. A fact whose endpoint kinds don't fit
  # is DROPPED (a mis-typed edge is worse than a missing one — same conservative ethos). This
  # catches the observed errors: `gateway hosted_on subnet` (should be in_subnet), `host
  # connects_site host` (connects_site is site↔site). `{subj_kinds, obj_kinds}`.
  @signatures %{
    # container → contained
    "contains" => {~w(site subnet cluster vlan), ~w(subnet host service vlan site)},
    # a service/host/cluster runs ON a host/cluster (NOT a gateway on a subnet)
    "hosted_on" => {~w(service host cluster), ~w(host cluster)},
    # something routes VIA routing infrastructure (gateway/firewall/host-hop)
    "routes_via" => {~w(subnet site host gateway cluster service), ~w(gateway firewall host)},
    # egress OUT via a gateway/firewall
    "egresses_via" => {~w(host subnet site cluster service), ~w(gateway firewall)},
    # site/tunnel connects site/tunnel (site↔site connectivity) — symmetric
    "connects_site" => {~w(site tunnel), ~w(site tunnel)},
    # a tunnel terminates at an endpoint
    "terminates_at" => {~w(tunnel), ~w(gateway firewall host)},
    # a tunnel/gateway/cluster CARRIES a subnet — ipsec "remote_subnets" + kubespray pod/service CIDRs
    "carries" => {~w(tunnel gateway cluster), ~w(subnet)},
    # an entity HAS an IP address (wiki inventory tables — public/private IP columns)
    "has_address" => {~w(host service gateway firewall cluster site), ~w(address)},
    # something is protected by a firewall
    "protected_by" => {~w(host subnet site service cluster), ~w(firewall)},
    # identity: alias_of is between same-kind endpoints
    "alias_of" => {:same_kind, :same_kind}
  }

  @system "You extract a MACRO network-topology skeleton from a passage. Output STRICT JSON " <>
            "only, no prose: " <>
            ~s|{"facts":[{"subject":"gw-a","subject_kind":"gateway","relation":"routes_via","object":"fw-lille","object_kind":"firewall"}]}. | <>
            "Each fact is (subject, relation, object) where subject/object are NAMED network " <>
            "things and relation is EXACTLY ONE of: contains, hosted_on, routes_via, " <>
            "egresses_via, connects_site, terminates_at, protected_by, alias_of. Each *_kind is " <>
            "EXACTLY ONE of: host, subnet, site, gateway, firewall, tunnel, cluster, service, " <>
            "vlan. Extract ONLY facts EXPLICITLY stated in the passage with NAMED endpoints. " <>
            "NEVER infer topology from proximity, naming, or outside knowledge. NEVER extract " <>
            "exact IP addresses, CIDR blocks, or firewall rules (leave specifics to a later " <>
            "authoritative pass). SKIP anything aspirational/planned/historical/ambiguous or " <>
            "needing multi-hop reasoning. Copy endpoint NAMES near-verbatim from the passage. " <>
            "At most 24 facts. If nothing qualifies, output {\"facts\":[]}."

  @typedoc "One extracted macro network fact: typed subject → relation → typed object."
  @type fact :: %{
          subject: String.t(),
          subject_kind: String.t(),
          relation: String.t(),
          object: String.t(),
          object_kind: String.t()
        }

  @doc "Does `body` show network-topology signals worth a (2nd) LLM extraction pass?"
  @spec network?(String.t()) :: boolean()
  def network?(body) when is_binary(body), do: Regex.match?(@signals, body)
  def network?(_), do: false

  @doc "The governed Phase-1 relation vocabulary (closed by discipline)."
  @spec relations() :: [String.t()]
  def relations, do: @relations

  @doc "The governed network-entity kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Extract macro network facts from `body` (only if `network?/1`). `opts`: `:gen_fun`, `:model`,
  `:max_passage`. Returns the validated `fact()` list (possibly empty). Pure w.r.t. the graph —
  writing is `write/3`.
  """
  @spec extract(String.t(), keyword()) :: [fact()]
  def extract(body, opts \\ []) when is_binary(body) do
    if network?(body) do
      gen = Keyword.get(opts, :gen_fun, &Generation.generate/3)
      model = Keyword.get(opts, :model) || "qwen3:14b"
      max_passage = Keyword.get(opts, :max_passage, @max_passage)
      passage = String.slice(body, 0, max_passage)
      prompt = "PASSAGE:\n" <> passage <> "\n\nJSON:"

      case gen.(model, prompt, json: false, system: @system) do
        {:ok, raw} ->
          raw
          |> parse()
          |> Enum.map(&validate(&1, passage))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.take(@max_facts)

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  @doc """
  Write `facts` for source `node` as namespaced network `entity` nodes + `is_a` type edges + the
  governed relation claim-edges (symmetric relations doubled). Returns the fresh edge ids (the
  caller folds them into the enrichment `reconcile` kept-set so they are not re-deleted). Network
  scope inherits the source node's scope (per-source, no-leak). Each edge carries `source_node_id`
  for ghost-purge.

  `opts` (Phase-2 IaC vs Phase-1 prose):
  - `:reliability` (default #{@reliability}) — Phase-1 prose is a low-reliability `hypothesis`;
    Phase-2 IaC (ground truth) passes ~0.85 so it wins aggregation over the prose hypothesis.
  - `:evidence_kind` (default `#{@evidence_kind}`) — Phase-2 passes `observation`.
  - `:origin` (default per-node) — Phase-2 passes a distinct `iac:<repo>` origin, so a repo fact
    that matches a wiki fact lands on the SAME edge with a 2nd origin (ADR-13 corroboration:
    `seen_count↑`); a repo fact the wiki lacks is undocumented; a wiki fact repo contradicts is a
    doc-vs-reality conflict. This is the "described vs actual" check.

  Facts are signature-filtered (`admissible?/1`) before writing, so a directly-fed (non-LLM) fact
  with a mis-typed relation↔kind is dropped, same as the extract path.
  """
  @spec write(map(), [fact()], String.t(), keyword()) :: [integer()]
  def write(node, facts, provenance, opts \\ []) do
    origin = Keyword.get(opts, :origin) || "enrich:origin:node:#{node.id}"
    reliability = Keyword.get(opts, :reliability, @reliability)
    evidence_kind = Keyword.get(opts, :evidence_kind, @evidence_kind)
    # S1: explicit upstream lineage (nil → Store derives from origin). Wiki-derived callers pass
    # "wiki:page:#{page_node}" so prose + table + api of the SAME page count as ONE vote.
    lineage = Keyword.get(opts, :lineage)
    scope = node.scope
    edge_opts = {reliability, evidence_kind, lineage}

    facts
    |> Enum.filter(&admissible?/1)
    |> Enum.flat_map(fn fact ->
      subj =
        ensure_entity(fact.subject, fact.subject_kind, scope, node, origin, provenance, edge_opts)

      obj =
        ensure_entity(fact.object, fact.object_kind, scope, node, origin, provenance, edge_opts)

      case {subj, obj} do
        {{:ok, subj_id, subj_edges}, {:ok, obj_id, obj_edges}} ->
          rel_edges =
            emit_relation(
              subj_id,
              obj_id,
              fact.relation,
              scope,
              node,
              origin,
              provenance,
              edge_opts
            )

          subj_edges ++ obj_edges ++ rel_edges

        _ ->
          []
      end
    end)
  end

  # A directly-fed fact is admissible if its vocab + relation↔kind signature are valid (the LLM
  # `extract` path already applies these via `validate/2` with grounding; repo facts skip grounding
  # but must still be well-typed).
  @spec admissible?(fact()) :: boolean()
  defp admissible?(%{subject_kind: sk, relation: rel, object_kind: ok})
       when is_binary(sk) and is_binary(rel) and is_binary(ok) do
    rel in @relations and sk in @kinds and ok in @kinds and valid_signature?(rel, sk, ok)
  end

  defp admissible?(_), do: false

  # --- write helpers ---------------------------------------------------------

  # Upsert a namespaced network entity node + its `is_a` edge to the kind marker. Returns
  # `{:ok, node_id, [is_a_edge_id]}` or `:error` (a write failure drops just this endpoint's fact).
  @spec ensure_entity(
          String.t(),
          String.t(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          {float(), String.t(), String.t() | nil}
        ) :: {:ok, integer(), [integer()]} | :error
  defp ensure_entity(
         name,
         kind,
         scope,
         node,
         origin,
         provenance,
         {reliability, evidence_kind, lineage}
       ) do
    key = entity_key(kind, name)
    ent = Store.upsert_node(@entity_type, key, scope: scope)
    # Kind markers are generic type labels shared across source scopes. Pin them public so a
    # src-scoped is_a edge satisfies edge <= glb(entity, marker).
    marker = Store.upsert_node(@marker_type, "net:kind:" <> kind, scope: "public")

    case Store.add_edge(ent, marker, "is_a", provenance,
           scope: scope,
           origin: origin,
           lineage: lineage,
           reliability: reliability,
           evidence_kind: evidence_kind,
           source_node_id: node.id
         ) do
      {:ok, %{id: id}} -> {:ok, ent, [id]}
      {:error, _} -> :error
    end
  end

  # Emit the governed relation claim-edge(s). Symmetric relations emit both directions with the
  # SAME provenance (evidential — each direction is a distinct claim); the read view folds them.
  @spec emit_relation(
          integer(),
          integer(),
          String.t(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          {float(), String.t(), String.t() | nil}
        ) :: [integer()]
  defp emit_relation(
         src,
         dst,
         relation,
         scope,
         node,
         origin,
         provenance,
         {reliability, evidence_kind, lineage}
       ) do
    directed = [{src, dst} | if(relation in @symmetric, do: [{dst, src}], else: [])]

    Enum.flat_map(directed, fn {s, d} ->
      case Store.add_edge(s, d, relation, provenance,
             scope: scope,
             origin: origin,
             lineage: lineage,
             reliability: reliability,
             evidence_kind: evidence_kind,
             source_node_id: node.id
           ) do
        {:ok, %{id: id}} -> [id]
        {:error, _} -> []
      end
    end)
  end

  # --- parse + validate ------------------------------------------------------

  @spec parse(String.t()) :: [map()]
  defp parse(raw) do
    json = slice_json(raw)

    case Jason.decode(json) do
      {:ok, %{"facts" => fs}} when is_list(fs) -> fs
      _ -> []
    end
  end

  # A fact is kept ONLY if: relation is in the governed vocabulary; both kinds are governed; the
  # relation↔endpoint-kind SIGNATURE fits (drops mis-typed edges like `gateway hosted_on subnet`);
  # both endpoint names are non-blank, NOT bare addresses (macro-only), and verbatim-grounded in
  # the passage (guards invented endpoints); and it is not a self-loop.
  @spec validate(map(), String.t()) :: fact() | nil
  defp validate(
         %{
           "subject" => subj,
           "subject_kind" => sk,
           "relation" => rel,
           "object" => obj,
           "object_kind" => ok
         },
         passage
       )
       when is_binary(subj) and is_binary(sk) and is_binary(rel) and is_binary(obj) and
              is_binary(ok) do
    s = String.trim(subj)
    o = String.trim(obj)

    if rel in @relations and sk in @kinds and ok in @kinds and
         valid_signature?(rel, sk, ok) and
         valid_name?(s, passage) and valid_name?(o, passage) and
         not (sk == ok and String.downcase(s) == String.downcase(o)) do
      %{subject: s, subject_kind: sk, relation: rel, object: o, object_kind: ok}
    else
      nil
    end
  end

  defp validate(_, _), do: nil

  # Does the (relation, subject_kind, object_kind) triple fit the governed signature? Unknown
  # relations (shouldn't reach here — `rel in @relations` gates first) pass. `:same_kind` relations
  # (alias_of) require matching endpoint kinds.
  @spec valid_signature?(String.t(), String.t(), String.t()) :: boolean()
  defp valid_signature?(rel, sk, ok) do
    case Map.get(@signatures, rel) do
      {:same_kind, :same_kind} -> sk == ok
      {subj_kinds, obj_kinds} -> sk in subj_kinds and ok in obj_kinds
      nil -> true
    end
  end

  # A valid Phase-1 endpoint name: non-blank, not a bare IP/CIDR (addresses wait for Phase-2), and
  # near-verbatim present in the source passage.
  @spec valid_name?(String.t(), String.t()) :: boolean()
  defp valid_name?(name, passage) do
    name != "" and not Regex.match?(@address_shape, name) and grounded?(name, passage)
  end

  defp grounded?(name, passage), do: String.contains?(normalize(passage), normalize(name))

  defp normalize(s), do: s |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Namespaced entity key (blackboard Decision 1) — the `net:<kind>:` prefix prevents the
  # aggregation collision a bare `entity` name would cause across domains.
  @spec entity_key(String.t(), String.t()) :: String.t()
  defp entity_key(kind, name), do: "net:" <> kind <> ":" <> normalize(name)

  # Take the outermost {...} span (stray think/prose tokens don't break decode) — same robust
  # slice the claim + procedure parsers use.
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
  def max_facts, do: @max_facts
end
