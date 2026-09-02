defmodule Swarm.Core do
  @moduledoc """
  The kernel's outward Core API logic — the SINGLE VOICE (Domain 11). It owns
  cognition: route the question through the gate, retrieve from the graph
  (tier-tools) or escalate to the consilium, and compose ONE cited,
  confidence-tagged answer. Channels (CLI, web, chat) only render this; they hold
  no cognition.

  Explainability: every answer carries its citations — the "because Y" behind
  "I said X". Fail-loud: a failed escalation returns a low-confidence answer with
  no citations, never raw unsynthesized text.
  """

  alias Swarm.{Activity, AnswerRecords, Consilium, Conversations, Deliberation, Gate, Repo}
  alias Swarm.Graph.{Aggregation, DocumentKind, Neighborhood, Procedure, Retrieval}
  alias Swarm.WorldMap
  alias Swarm.WorldMap.SemanticRouter

  require Logger

  @default_scopes ["public"]
  @search_limit 10
  # Cap the grounding fed to the consilium: enough to carry the answer-bearing
  # passages of the top hits, bounded so a long corpus can't blow the token ceiling
  # or dilute the signal (the consilium also budget-refuses over-ceiling).
  @grounding_char_budget 8_000
  # Claim facts get their OWN sub-budget so a burst of facts can never crowd the
  # retrieved passages out of the grounding (code review); passages keep the full
  # budget below, facts are bounded on top.
  @facts_char_budget 2_000
  @stopwords ~w(the a an of to and or for with about how what which why who when
                where is are was were do does did can could should would related
                show find list recent get see me my our your this that these those)

  @typedoc """
  Answer-result algebra (T6): every answer is typed by its outcome —
  `:found` (a real, supported answer), `:not_found` (the lookup resolved to
  nothing — distinct, the turn survives), `:partial` (some sources failed; the
  answer is incomplete and says so), `:error` (a genuine transport/adapter
  failure — distinct from not-found, never silent, never a raw leak).
  """
  @type status :: :found | :not_found | :partial | :error
  @type citation :: %{
          :source => String.t(),
          :ref => String.t(),
          :confidence => float(),
          optional(:url) => String.t()
        }
  @type answer :: %{
          :answer => String.t(),
          :confidence => float(),
          :tier => String.t(),
          :status => status(),
          :citations => [citation()],
          # Set only on an escalation that retained a deliberation for a
          # non-anonymous asker (ADR-15); absent otherwise.
          optional(:ask_ref) => String.t()
        }
  @typedoc """
  A retrieval hit. Content hits (the hybrid arm) additionally carry the cited
  `spans` (the answer-bearing passages, not just the title) and the absolute-cosine
  `relevance` (the calibrated retrieval signal) — title/identity key hits do not.
  """
  @type hit :: %{
          :id => integer(),
          :type => String.t(),
          :key => String.t(),
          :score => float(),
          optional(:spans) => [%{ordinal: integer(), text: String.t()}],
          optional(:relevance) => float(),
          optional(:source_ref) => String.t()
        }
  @typedoc "Typed retrieval outcome: ok / partial (some sources failed) / hard error."
  @type retrieval :: {:ok, [hit()]} | {:partial, [hit()], [term()]} | {:error, term()}

  @doc """
  Answer a question (the single voice). `opts`: `:scopes`, `:retriever`
  (injectable; default the graph search), plus gate/consilium injectables. Always
  returns a typed `answer()` — an expected-empty or a transport failure is a
  structured result, never a raised exception in the caller's turn.
  """
  @spec ask(String.t(), keyword()) :: answer()
  def ask(query, opts \\ []) when is_binary(query) do
    scopes = Keyword.get(opts, :scopes, @default_scopes)
    retriever = Keyword.get(opts, :retriever, &retrieve/3)
    viewer = Keyword.get(opts, :viewer, "")

    first_person = first_person?(query)

    # "my X" without a known asker: can't resolve identity — limit, don't guess
    # (the asker-identity contract, T8 / P11). Identity mapping is the channel's.
    answer =
      if first_person and viewer == "" do
        identity_required()
      else
        case source_link_answer(query, scopes, opts) do
          {:ok, answer} ->
            answer

          :none ->
            # "my X" with an asker → narrow retrieval to that asker's items.
            owner = if first_person, do: viewer, else: nil

            decision = Gate.route(query, opts)

            case decision.tier do
              :tier0 -> tier0_answer(decision.intent)
              :tier_tools -> tools_answer(query, scopes, retriever, owner, opts)
              :escalate -> escalate_answer(query, scopes, retriever, owner, opts)
            end
        end
      end

    record_answer(query, viewer, scopes, answer)
  end

  # tier0 is canned + zero-LLM — it NEVER escalates. Off-mission requests are
  # deflected here (T9 cost guarantee): a poem/recipe costs no model call. The
  # default copy is neutral; register/persona/rotation are a channel+skill concern
  # (Ports.Skill), never the kernel (presentation-determinism standard).
  defp tier0_answer(:off_topic), do: deflect()
  defp tier0_answer(:farewell), do: farewell()
  defp tier0_answer(_), do: greeting()

  defp deflect do
    %{
      answer: "I stick to the knowledge base — ask me about your docs, tickets, or projects.",
      confidence: 0.9,
      tier: "tier0",
      status: :found,
      citations: []
    }
  end

  defp farewell do
    %{answer: "Goodbye.", confidence: 0.9, tier: "tier0", status: :found, citations: []}
  end

  # Possessives only — NOT bare "me" ("tell me about X" is not an ownership query).
  @first_person ~r/\b(my|mine)\b/i
  defp first_person?(query), do: Regex.match?(@first_person, query)

  defp identity_required do
    %{
      answer: "I can't tell whose items you mean — identify yourself (sign in) and ask again.",
      confidence: 0.0,
      tier: "tier0",
      status: :not_found,
      citations: []
    }
  end

  # Typed retrieval: a genuine DB/transport failure becomes `{:error, …}` (caught
  # here, never raised into the turn — the not-found-vs-outage scar). Empty is
  # `{:ok, []}`. The rescue is NARROW — only transport exceptions — so a
  # programmer bug still crashes loudly instead of being mislabeled an "outage".
  @spec retrieve(String.t(), [String.t()], keyword()) :: retrieval()
  defp retrieve(query, scopes, opts) do
    {:ok, hybrid_hits(query, scopes, opts)}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:retrieval_failed, Exception.message(e)}}
  end

  # The default retriever (swarm ADR-14 §5): content recall through the hybrid,
  # floor-gated `Retrieval.search` (so the answer path inherits both content-level
  # matching and the ability to return nothing for out-of-scope queries), unioned
  # with the title/identity key search. An owner-scoped ("my X") ask is an
  # ownership lookup the content retriever cannot narrow, so it stays purely
  # key-based (the T8 contract). `Retrieval.search` degrades to lexical-only if the
  # embedding boundary is unreachable, so this never hard-fails on a missing ML
  # sidecar — a genuine DB transport failure still propagates to the rescue above.
  @spec hybrid_hits(String.t(), [String.t()], keyword()) :: [hit()]
  defp hybrid_hits(query, scopes, opts) do
    owner = Keyword.get(opts, :owner)
    limit = Keyword.get(opts, :limit, @search_limit)
    active_hits = active_source_hits(query, scopes, opts)

    cond do
      active_hits != [] ->
        active_hits

      owner ->
        query |> search(scopes, opts) |> gate_key_hits(query)

      true ->
        key_hits = query |> search(scopes, opts) |> gate_key_hits(query)

        content_hits =
          query
          |> Retrieval.search(scopes, limit: limit, expand: false)
          |> Map.fetch!(:memories)
          |> Enum.map(
            &%{
              id: &1.node_id,
              type: &1.type,
              key: &1.key,
              score: &1.relevance,
              # Keep the cited passages + the calibrated relevance — the consilium is
              # grounded on the answer-bearing text (not the title), and calibration
              # anchors on `relevance` (was discarded here; the precise-lookup gap).
              spans: &1.spans,
              relevance: &1.relevance,
              source_ref: &1.source_ref
            }
          )

        merge_hits(content_hits, key_hits, limit)
    end
  end

  # Relevance gate on the title/identity (key-ILIKE) arm: a key hit must match at
  # least HALF (ceil) of the query's significant terms — so an entity that
  # incidentally shares ONE word with a multi-word off-topic question ("cook" in
  # "how do I cook a mushroom risotto" matching a node "Villa Cook") is NOT
  # admitted, and the answer path can still refuse. A single- or two-term query
  # (e.g. "ticket", "about postgres") needs just one term, so identity/inventory
  # lookups keep working. The fraction (not a flat `min(2,…)`) tolerates filler
  # words that survive stop-word stripping (e.g. "tell").
  @spec gate_key_hits([hit()], String.t()) :: [hit()]
  defp gate_key_hits(hits, query) do
    terms = query_terms(query)
    needed = div(length(terms) + 1, 2)

    if needed == 0 do
      hits
    else
      Enum.filter(hits, fn h ->
        kd = String.downcase(h.key)
        Enum.count(terms, &key_term_match?(kd, &1)) >= needed
      end)
    end
  end

  # A query term matches a key only as a DELIMITED token (start/end or a
  # non-alphanumeric boundary, so `_`/`/`/`-`/space all separate) — never a bare
  # substring. Kills incidental false matches ("war" inside "Award", "change"
  # inside "exchange") while still matching `storage` in `/docs/storage_engine.md`.
  @spec key_term_match?(String.t(), String.t()) :: boolean()
  defp key_term_match?(key_down, term) do
    Regex.match?(~r/(^|[^[:alnum:]])#{Regex.escape(term)}([^[:alnum:]]|$)/u, key_down)
  end

  defp active_source_hits(query, scopes, opts) do
    active = active_keys(opts)

    if source_link_query?(query) and active != [] do
      active
      |> visible_active_content_hits(scopes)
      |> Enum.map(&Map.put(&1, :score, 1.0))
    else
      []
    end
  end

  defp source_link_answer(query, scopes, opts) do
    hits = active_source_hits(query, scopes, opts)

    cond do
      hits == [] ->
        :none

      true ->
        citations = Enum.map(hits, &cite/1)
        links = citations |> Enum.map(&Map.get(&1, :url)) |> Enum.reject(&(&1 in [nil, ""]))

        text =
          case links do
            [] ->
              "I have the cited source, but no link template is configured for it."

            [one] ->
              one

            many ->
              Enum.map_join(many, "\n", &"- #{&1}")
          end

        {:ok,
         %{
           answer: text,
           confidence: 0.9,
           tier: "tier_tools",
           status: :found,
           citations: citations
         }}
    end
  end

  defp source_link_query?(query) do
    query
    |> String.downcase()
    |> String.match?(
      ~r/(^|[^[:alnum:]])(link|url|source|citation|wiki|page|written|посилання|лінк|джерел|сторінк|вікі)([^[:alnum:]]|$)/u
    )
  end

  defp visible_active_content_hits(active_keys, scopes) do
    Repo.query!(
      """
      SELECT n.id, n.type, coalesce(nullif(n.provenance->>'display_key', ''), n.key), n.reliability, c.source_ref
      FROM node n
      JOIN content c ON c.node_id = n.id
      WHERE n.scope = ANY($1)
        AND (coalesce(nullif(n.provenance->>'display_key', ''), n.key) = ANY($2) OR n.key = ANY($2))
      ORDER BY array_position($2, coalesce(nullif(n.provenance->>'display_key', ''), n.key))
      LIMIT 5
      """,
      [scopes, active_keys]
    )
    |> Map.get(:rows)
    |> Enum.map(fn [id, type, key, reliability, source_ref] ->
      %{
        id: id,
        type: type,
        key: key,
        confidence: reliability,
        source_ref: source_ref,
        spans: [],
        relevance: 1.0
      }
    end)
  end

  # Union content hits (primary, ranked by relevance) with key hits, de-duped by
  # node id, capped at the limit.
  @spec merge_hits([hit()], [hit()], pos_integer()) :: [hit()]
  defp merge_hits(primary, secondary, limit) do
    seen = MapSet.new(primary, & &1.id)

    (primary ++ Enum.reject(secondary, &MapSet.member?(seen, &1.id)))
    |> Enum.take(limit)
  end

  @doc """
  Scope-filtered retrieval over the graph (default-deny). Matches significant
  query terms against node identity keys. Performance: one indexed `ILIKE ANY`
  query, bounded by `:limit`.
  """
  @spec search(String.t(), [String.t()], keyword()) :: [hit()]
  def search(_query, [], _opts), do: []

  def search(query, scopes, opts) do
    limit = Keyword.get(opts, :limit, @search_limit)
    owner = Keyword.get(opts, :owner)

    case patterns(query) do
      [] ->
        []

      pats ->
        {sql, params} = search_sql(scopes, pats, limit, owner)
        %{rows: rows} = Repo.query!(sql, params)
        Enum.map(rows, fn [id, type, key] -> %{id: id, type: type, key: key, score: 1.0} end)
    end
  end

  # With an `owner` (a resolved asker, T8), AND a `key ILIKE %owner%` filter so
  # "my X" returns only the asker's items — still scope-filtered (default-deny).
  defp search_sql(scopes, pats, limit, nil) do
    display_key = display_key_sql()

    {"SELECT id, type, #{display_key} AS key FROM node WHERE scope = ANY($1) AND (#{display_key} ILIKE ANY($2) OR key ILIKE ANY($2)) ORDER BY key LIMIT $3",
     [scopes, pats, limit]}
  end

  defp search_sql(scopes, pats, limit, owner) do
    display_key = display_key_sql()

    {"SELECT id, type, #{display_key} AS key FROM node WHERE scope = ANY($1) AND (#{display_key} ILIKE ANY($2) OR key ILIKE ANY($2)) AND (#{display_key} ~* $4 OR key ~* $4) ORDER BY key LIMIT $3",
     [scopes, pats, limit, owner_boundary(owner)]}
  end

  defp display_key_sql, do: "coalesce(nullif(provenance->>'display_key', ''), key)"

  # Match the owner as a DELIMITED token, not a bare substring, so a short id
  # ("al") can't match another asker ("alice-…"). A convenience to reduce
  # mis-attribution — NOT the security boundary (scopes are; see ADR-7). Metachars
  # in the id are escaped so the value can't act as a regex.
  defp owner_boundary(owner) do
    escaped = Regex.replace(~r/[^[:alnum:]]/u, owner, "\\\\\\0")
    "(^|[^[:alnum:]])" <> escaped <> "([^[:alnum:]]|$)"
  end

  @doc """
  Bounded, scope-enforced neighborhood projection around a node (ADR-15) — the
  read-only "connections" surface. Delegates to `Swarm.Graph.Neighborhood`; the
  kernel enforces scope (the channel passes only an identity + allowed scopes).
  `opts`: `:scopes`, `:depth`, `:node_limit`, `:relation_types`.
  """
  @spec neighborhood(integer(), keyword()) ::
          {:ok, Neighborhood.result()} | {:error, :not_found}
  defdelegate neighborhood(center_id, opts), to: Neighborhood, as: :query

  @doc """
  Fetch a retained panel-vs-judge deliberation by `ask_ref` (ADR-15), returned only
  to the owning `viewer` whose current `scopes` cover the asking scopes — otherwise
  `:not_found` (existence never revealed). Delegates to `Swarm.Deliberation`.
  """
  @spec deliberation(String.t(), String.t(), [String.t()]) ::
          {:ok, Deliberation.record()} | :not_found
  defdelegate deliberation(ask_ref, viewer, scopes), to: Deliberation, as: :fetch

  @doc """
  Record an external answer rating by the viewer who received the answer.

  ADR-11: this stores user feedback only; it does not let the system grade itself
  and does not mutate graph reward.
  """
  @spec rate_answer(String.t(), String.t(), [String.t()], AnswerRecords.rating() | String.t()) ::
          {:ok, AnswerRecords.rating()} | :not_found | :bad_request
  defdelegate rate_answer(ask_ref, viewer, scopes, rating), to: AnswerRecords, as: :rate

  @doc """
  One poll of the scope-safe worker/job ActivityFeed (ADR-15). `opts`: `:scopes`,
  `:cursor` (opaque; `""` ⇒ most recent), `:limit`, `:kinds`. Delegates to
  `Swarm.Activity`; events are already scope-filtered and the cursor is opaque.
  """
  @spec activity_feed(keyword()) :: Activity.page()
  defdelegate activity_feed(opts), to: Activity, as: :feed

  @doc """
  The kernel's **self-model** (T8): what it knows, how fresh, what it can do —
  from REAL state, never a guess. Graph size + per-type inventory + last activity
  + embedding-namespace stamps (ADR-6) + live capabilities (attached connectors,
  panel width). This is how the system avoids "I have no knowledge base" while
  thousands of docs sit indexed.
  """
  @spec status() :: %{
          nodes: integer(),
          edges: integer(),
          inventory: [%{type: String.t(), count: integer()}],
          last_activity: String.t(),
          namespaces: [map()],
          capabilities: [String.t()]
        }
  def status do
    %{rows: [[nodes]]} = Repo.query!("SELECT count(*) FROM node")
    %{rows: [[edges]]} = Repo.query!("SELECT count(*) FROM edge")

    %{rows: inv} =
      Repo.query!("SELECT type, count(*) FROM node GROUP BY type ORDER BY count(*) DESC")

    %{rows: [[last]]} = Repo.query!("SELECT max(updated_at) FROM node")

    %{rows: ns} =
      Repo.query!("SELECT namespace, model, dim, status FROM schema_meta ORDER BY namespace")

    %{
      nodes: nodes,
      edges: edges,
      inventory: Enum.map(inv, fn [t, c] -> %{type: t, count: c} end),
      last_activity: format_ts(last),
      namespaces:
        Enum.map(ns, fn [n, m, d, s] -> %{namespace: n, model: m, dim: d, status: s} end),
      capabilities: capabilities()
    }
  end

  # Live capabilities from real state: attached connector names + panel models.
  # Resilient — if the registry isn't running (some test contexts), report none.
  defp capabilities do
    # Catch only a process-level :exit (registry not running, e.g. some test
    # contexts) → report no connectors. A real code bug is NOT swallowed (no broad
    # rescue) — a self-model must not silently hide a fault as "no capabilities".
    connectors =
      try do
        Enum.map(Swarm.Plugins.Registry.connectors(), & &1.name)
      catch
        :exit, _ -> []
      end

    # The CONFIGURED panel width (not a reachability probe).
    panel = "consilium:#{length(Swarm.Config.consilium().panel)}-model-panel"
    Enum.sort(connectors) ++ [panel]
  end

  defp format_ts(nil), do: ""
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_ts(other), do: to_string(other)

  # --- tiers ---------------------------------------------------------------

  defp greeting do
    %{
      answer: "Hello — ask me about the knowledge base.",
      confidence: 0.9,
      tier: "tier0",
      status: :found,
      citations: []
    }
  end

  defp tools_answer(query, scopes, retriever, owner, opts) do
    case retriever.(query, scopes, retrieval_opts(opts, owner)) do
      {:ok, []} ->
        case try_structured_from_tools(query, scopes, [], opts) do
          {:serve, answer} -> answer
          :escalate -> not_found(query, "tier_tools")
        end

      {:ok, hits} ->
        case try_structured_from_tools(query, scopes, hits, opts) do
          {:serve, answer} ->
            answer

          :escalate ->
            %{
              answer: "Found #{length(hits)} matching item(s) in the knowledge base.",
              confidence: 0.7,
              tier: "tier_tools",
              status: :found,
              citations: Enum.map(hits, &cite/1)
            }
        end

      {:partial, hits, failed} ->
        case try_structured_from_tools(query, scopes, hits, opts) do
          {:serve, answer} ->
            answer

          :escalate ->
            %{
              answer:
                "Partial results — #{length(hits)} item(s); #{length(failed)} source(s) unavailable.",
              confidence: 0.5,
              tier: "tier_tools",
              status: :partial,
              citations: Enum.map(hits, &cite/1)
            }
        end

      {:error, reason} ->
        error_result(reason, "tier_tools")
    end
  end

  defp try_structured_from_tools(query, scopes, hits, opts) do
    profile = Aggregation.entity_profile(query, scopes)
    try_structured_gate(query, scopes, hits, profile, opts)
  end

  defp escalate_answer(query, scopes, retriever, owner, opts) do
    case retriever.(query, scopes, retrieval_opts(opts, owner)) do
      {:error, reason} ->
        error_result(reason, "escalate")

      result ->
        {hits, base_status} =
          case result do
            {:ok, h} -> {h, :found}
            {:partial, h, _failed} -> {h, :partial}
          end

        synthesize(query, hits, base_status, scopes, opts)
    end
  end

  defp retrieval_opts(opts, owner) do
    opts
    |> Keyword.put(:limit, @search_limit)
    |> Keyword.put(:owner, owner)
  end

  defp synthesize(query, hits, base_status, scopes, opts) do
    # Entity aggregation (STEP 2): gather the claim graph about the query's entities,
    # grouped by canonical predicate + corroboration-ranked, scope-enforced — so a
    # "what is X" answer synthesizes across the corpus, not just whatever chunk landed.
    profile = Aggregation.entity_profile(query, scopes)

    # Tier-routing gate (ADR-17 §3, Fork B): try to answer from the pre-built world-map
    # structure BEFORE paying the consilium. Fail-closed + circuit-broken — a served
    # answer is only ever backed by current, citable structure; anything else (and any
    # gate slowness) falls through to the consilium exactly as before. OFF by default
    # (config-gated) until the false-serve/needless-escalation council go/no-go.
    case try_structured_gate(query, scopes, hits, profile, opts) do
      {:serve, answer} -> answer
      :escalate -> deliberate(query, hits, base_status, scopes, profile, opts)
    end
  end

  defp deliberate(query, hits, base_status, scopes, profile, opts) do
    grounding_hits = gate_grounding_hits(query, hits)
    grounding_profile = gate_grounding_profile(query, profile, grounding_hits)
    grounding = build_grounding(grounding_profile, grounding_hits) |> prepend_history(opts)

    case Consilium.deliberate(query, Keyword.put(opts, :grounding, grounding)) do
      {:ok, verdict} ->
        # Retain the panel-vs-judge verdict (ADR-15) so the answer can re-open its
        # deliberation — only for a non-anonymous asker, under the asking scopes; a
        # single insert AFTER the LLM returned. "" when not retained.
        viewer = Keyword.get(opts, :viewer, "")
        ask_ref = Deliberation.maybe_persist(verdict, viewer, scopes)
        calibrated_answer(query, verdict, grounding_hits, grounding_profile, base_status, ask_ref)

      {:error, reason} ->
        # Fail-loud: a synthesis failure is an ERROR (distinct from not-found),
        # quarantined low-confidence, never raw panel text. Reason logged, not leaked.
        error_result({:escalation_failed, reason}, "escalate")
    end
  end

  # --- ADR-17 tier-routing gate (Fork B) wiring ------------------------------

  # Never let the gate make an ask SLOWER than pure escalation (spec §3, gemini's
  # sink-risk): the Stage-2 entail check runs under a hard time budget; a timeout
  # or crash escalates, so the worst case is (semantic routing + breaker + consilium),
  # capped — never an unbounded double-pay.
  #
  # Budget note (2026-09-02): after semantic routing entered the gate path, live
  # Core.ask warm structured probes measured up to ~3.8s end-to-end, and the first
  # cold post-deploy probe tripped the old 3s breaker before the qwen entail model
  # finished loading. The breaker bounds the LLM-bearing Stage-2 check only; semantic
  # embedding happens before it. Keep this ceiling explicit so any new gate stage must
  # be paid for deliberately.
  @gate_breaker_default_ms 7_000

  @spec try_structured_gate(String.t(), [String.t()], [hit()], Aggregation.profile(), keyword()) ::
          {:serve, answer()} | :escalate
  defp try_structured_gate(query, scopes, hits, profile, opts) do
    if tier_gate_enabled?(opts) do
      # Candidate keys: the query's procedure-shaped entities FIRST (overlap-ranked — a
      # key-only procedure entity ranks poorly in content retrieval, so the gate would
      # otherwise never see it; ADR-17 #2), then the retrieval hits, then any
      # conversational `active_keys` (chat-thread epic 2 — a pronoun follow-up like
      # "its dependencies?" has NO usable key of its own; the channel echoes back the
      # previous turn's citation keys here instead of an LLM rewriting the query text).
      # Order matters: the gate picks the best-matching candidate, so query-derived
      # keys still lead — active_keys only fill in what the query text alone can't.
      # No new no-leak surface: a bogus/foreign-scoped key here simply fails the
      # gate's existing scope+evidence checks below, same as a wrong guess would.
      descriptor = coverage_descriptor(query, scopes, hits, profile, opts, :cheap)

      if semantic_fallback?(descriptor) do
        semantic = SemanticRouter.route(query, opts)
        descriptor = coverage_descriptor(query, scopes, hits, profile, opts, semantic)
        run_gate(descriptor, opts, scopes)
      else
        run_gate(descriptor, opts, scopes)
      end
    else
      :escalate
    end
  rescue
    # Fail-closed: the coverage probe (`describe` runs `Procedure.steps` DB queries in
    # THIS process — outside the breaker task, for Ecto connection ownership) must never
    # raise into the ask; any error degrades to the consilium (codex review).
    e ->
      Logger.warning("world-map gate: coverage probe failed (#{inspect(e)}) — escalating")
      :escalate
  end

  defp coverage_descriptor(query, scopes, hits, profile, opts, semantic) do
    {semantic_route, candidate_opts} =
      case semantic do
        %{route: route, query_vec: vec} -> {route, [query_vec: vec]}
        _ -> {:none, []}
      end

    candidate_keys =
      Enum.uniq(
        Procedure.candidates(query, scopes, candidate_opts) ++ hit_keys(hits) ++ active_keys(opts)
      )

    neighborhood_opts =
      Enum.flat_map(WorldMap.Domain.neighborhood_domains(), fn dom ->
        [
          {:"#{dom.key}_keys",
           Enum.uniq(dom.candidates_fun.(query, scopes, candidate_opts) ++ active_keys(opts))},
          {:"#{dom.key}_serve", neighborhood_serve?(dom, opts)},
          {:"#{dom.key}_min_corroboration", neighborhood_min_corroboration(dom)}
        ]
      end)

    WorldMap.Coverage.describe(
      query,
      scopes,
      [
        candidate_keys: candidate_keys,
        profile: profile,
        entity_serve: entity_serve?(opts),
        semantic_route: semantic_route
      ] ++ neighborhood_opts
    )
  end

  defp semantic_fallback?(%WorldMap.Coverage.Descriptor{intent: :unknown}), do: true

  defp semantic_fallback?(%WorldMap.Coverage.Descriptor{blockers: blockers}) do
    Enum.any?(blockers, &(&1 in [:no_candidate, :no_corroboration]))
  end

  # Run the (LLM-bearing) sufficiency check under a NOLINK task bounded to the breaker:
  # a timeout OR a crash surfaces as `{:exit, _}`/`nil` here and degrades to escalate — so
  # a slow/crashing gate never takes the ask process down (async_nolink, not async) and
  # never double-pays gate + consilium unbounded (codex review + gemini's sink-risk).
  defp run_gate(descriptor, opts, scopes) do
    gate_opts = Keyword.take(opts, [:entail_fun])
    gate_opts = Keyword.put(gate_opts, :scopes, scopes)

    task =
      Task.Supervisor.async_nolink(WorldMap.GateTaskSupervisor, fn ->
        WorldMap.Gate.sufficient?(descriptor, gate_opts)
      end)

    breaker_ms = gate_breaker_ms()

    case Task.yield(task, breaker_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:serve, %WorldMap.Gate.Answer{} = answer, audit}} ->
        log_gate(audit)
        {:serve, structured_answer(answer)}

      {:ok, {:escalate, audit}} ->
        log_gate(audit)
        :escalate

      _timeout_or_crash ->
        Logger.info("world-map gate: circuit-break (>#{breaker_ms}ms or crash) — escalating")

        :escalate
    end
  end

  defp gate_breaker_ms do
    Application.get_env(:swarm, :tier_gate, [])
    |> Keyword.get(:breaker_ms, @gate_breaker_default_ms)
  end

  # Map the gate's evidence-closed answer onto the Core `answer()` shape. The gate's own
  # `a.citations` are OPAQUE audit labels (e.g. "corroboration:1" — no source identity);
  # `a.key`, when present, is the real served entity/subject key. Both become `citation()`s
  # so a channel's `active_keys` echo (chat-thread epic 2) has something usable to carry
  # forward — without `a.key` here, a pronoun follow-up right after a structured-served
  # turn would only see "corroboration:1" and could never resolve back to the entity.
  @spec structured_answer(WorldMap.Gate.Answer.t()) :: answer()
  defp structured_answer(%WorldMap.Gate.Answer{} = a) do
    key_citation = if a.key, do: [%{source: "structured", ref: a.key, confidence: 1.0}], else: []

    %{
      answer: a.text,
      confidence: a.confidence,
      tier: "structured",
      status: :found,
      citations:
        key_citation ++ Enum.map(a.citations, &%{source: "structured", ref: &1, confidence: 1.0})
    }
  end

  # Candidate entity keys to probe for procedures — the retrieval hits' keys, bounded.
  @spec hit_keys([hit()]) :: [String.t()]
  defp hit_keys(hits), do: hits |> Enum.map(& &1.key) |> Enum.uniq() |> Enum.take(8)

  # Client-supplied (chat-thread epic 2) — sanitize before folding into the gate's
  # candidate list: drop blanks, cap the count (a buggy/abusive channel sending an
  # unbounded list is just noise here, never a correctness or leak issue, but still
  # bounded on principle).
  @spec active_keys(keyword()) :: [String.t()]
  defp active_keys(opts) do
    opts
    |> Keyword.get(:active_keys, [])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.take(20)
  end

  # OFF by default (config `:swarm, :tier_gate, enabled: true`); `opts[:tier_gate]`
  # overrides per-call (tests, shadow measurement). Until the go/no-go council, wiring
  # the gate in is behaviour-neutral live.
  @spec tier_gate_enabled?(keyword()) :: boolean()
  defp tier_gate_enabled?(opts) do
    Keyword.get(opts, :tier_gate, Application.get_env(:swarm, :tier_gate, [])[:enabled] == true)
  end

  # H1 entity-profile serve path: still OFF by default after the 2026-07-06 false-serves.
  # This opt-in is for branch-only calibration/shadow measurement until H1's go/no-go numbers pass.
  @spec entity_serve?(keyword()) :: boolean()
  defp entity_serve?(opts) do
    Keyword.get(
      opts,
      :entity_serve,
      Application.get_env(:swarm, :tier_gate, [])[:entity_serve] == true
    )
  end

  # A neighborhood domain's serve flag. Each path is OFF by default (like entity_serve) until it is
  # calibrated (its own `Gate.*Calibration`, false-serve ~0). `opts[<domain>_serve]` (tests / shadow
  # measurement) overrides the config `:swarm, :tier_gate, <domain>_serve` — e.g. `SWARM_TIER_GATE_
  # NETWORK_SERVE`/`_WHO_SERVE` → the network/who domain's serve flag.
  @spec neighborhood_serve?(WorldMap.Domain.t(), keyword()) :: boolean()
  defp neighborhood_serve?(%WorldMap.Domain{serve_opt: serve_opt}, opts) do
    Keyword.get(opts, serve_opt, Application.get_env(:swarm, :tier_gate, [])[serve_opt] == true)
  end

  # A neighborhood domain's corroboration floor: config `:swarm, :tier_gate, <domain>_min_corroboration`
  # overrides the registry default (network 2 = safe/narrow, staging runs 1 = wider entail-veto-guarded;
  # who is authoritative at 1). See `Coverage.describe`.
  @spec neighborhood_min_corroboration(WorldMap.Domain.t()) :: pos_integer()
  defp neighborhood_min_corroboration(%WorldMap.Domain{key: key, min_corroboration: default}) do
    Application.get_env(:swarm, :tier_gate, [])[:"#{key}_min_corroboration"] || default
  end

  @spec log_gate(WorldMap.Gate.Audit.t()) :: :ok
  defp log_gate(%WorldMap.Gate.Audit{} = audit) do
    Logger.info(
      "world-map gate: #{audit.decision} intent=#{audit.intent} " <>
        "blockers=#{inspect(audit.blockers)} stage2=#{inspect(audit.stage2)}"
    )

    :ok
  end

  # Confidence calibration (the lynchpin) — anchor the escalated answer's confidence
  # on (judge ∧ retrieval-signal ∧ groundedness) so a non-grounded answer cannot
  # return a high number (the judge self-reports 0.8–0.9 even when abstaining).
  # Decorrelated council (codex + gemini-3.1-pro): the judge's `supported` self-flag
  # gates groundedness (fail-closed); retrieval relevance is a ONE-SIDED CAP, never a
  # raw multiplier (multiplying raw cosine crushes legitimate answers — cosine-space
  # ≠ confidence-space); disagreement applies a gentle haircut.
  @relevance_floor 0.45
  @relevance_full 0.55
  @grounding_relative_floor 0.4
  @grounding_min_hits 3
  @grounding_claim_stopwords MapSet.new(@stopwords ++ ~w(at про розкажи))

  @spec calibrated_answer(
          String.t(),
          Consilium.verdict(),
          [hit()],
          Aggregation.profile(),
          status(),
          String.t()
        ) :: answer()
  defp calibrated_answer(query, verdict, hits, profile, base_status, ask_ref) do
    if verdict.supported do
      %{
        answer: verdict.answer,
        confidence:
          calibrate_confidence(
            verdict.confidence,
            verdict.disagreement,
            hits,
            profile.claim_support
          ),
        tier: "escalate",
        status: base_status,
        # Cite both the retrieved passages AND the claim facts that grounded the
        # answer — so a claim-only answer (no retrieval hits) is still explainable.
        citations: Enum.map(hits, &cite/1) ++ Enum.map(profile.facts, &fact_cite/1),
        ask_ref: ask_ref,
        agreement: agreement(verdict.disagreement)
      }
    else
      # The judge marked the answer NOT grounded (an abstention) — honest `:not_found`,
      # confidence 0.0, the standard not-found message (NOT the judge's "it's not in the
      # text" prose), no citations (we don't present examined pages as support). The
      # deliberation is still retained, so the dashboard can show that it deliberated.
      query
      |> not_found("escalate")
      |> Map.merge(%{
        confidence: 0.0,
        ask_ref: ask_ref,
        agreement: agreement(verdict.disagreement)
      })
    end
  end

  defp agreement(disagreement), do: max(0.0, min(1.0, 1.0 - disagreement))

  defp record_answer(query, viewer, scopes, answer) do
    case AnswerRecords.maybe_persist(viewer, scopes, query, answer) do
      "" -> answer
      ask_ref -> Map.put(answer, :ask_ref, ask_ref)
    end
  rescue
    e ->
      Logger.warning("answer record persist failed (#{Exception.message(e)})")
      answer
  end

  # final = judge_confidence · agreement · evidence_cap, clamped to [0,1].
  @spec calibrate_confidence(float(), float(), [hit()], float() | nil) :: float()
  defp calibrate_confidence(judge_conf, disagreement, hits, claim_support) do
    agreement = 1.0 - 0.5 * disagreement
    clamp01(judge_conf * agreement * retrieval_cap(hits, claim_support))
  end

  # Evidence relevance as a ONE-SIDED cap, not a scalar (council): at/above the
  # "good in-scope" target it is 1.0 (a strong answer is NOT penalised → confidence ≈
  # judge·agreement); only marginal grounding (floor-band) caps it, and never below
  # 0.6 so a vocabulary-mismatch / multi-source answer is not crushed.
  # STEP 2 (gemini's #1 fix): the signal is the BEST of chunk relevance AND the
  # claim-profile support, so a claim-grounded "what is X" answer is not crushed by
  # weak/absent chunk relevance. No evidence signal at all (identity/lexical key hits,
  # no claims) ⇒ no cap (1.0) — those are exact-key answers, not penalised.
  # The evidence signal is the BEST PRESENT of chunk relevance and claim support.
  # `claim_support` is `nil` when there are NO claims (distinct from a present-but-
  # weak 0.0 — code review): only when NEITHER signal is present (no chunks, no
  # claims — an exact-key/identity answer) is there no cap.
  @spec retrieval_cap([hit()], float() | nil) :: float()
  defp retrieval_cap(hits, claim_support) do
    chunk =
      case Enum.flat_map(hits, fn h -> List.wrap(h[:relevance]) end) do
        [] -> nil
        rels -> Enum.max(rels)
      end

    case Enum.reject([chunk, claim_support], &is_nil/1) do
      [] -> 1.0
      signals -> ramp(Enum.max(signals))
    end
  end

  @spec ramp(float()) :: float()
  defp ramp(x) when x >= @relevance_full, do: 1.0
  defp ramp(x) when x <= @relevance_floor, do: 0.6
  defp ramp(x), do: 0.6 + 0.4 * (x - @relevance_floor) / (@relevance_full - @relevance_floor)

  @spec clamp01(float()) :: float()
  defp clamp01(x), do: x |> max(0.0) |> min(1.0)

  # The relevance floor used for confidence is a cap, not a source-selection rule.
  # Grounding needs its own relative gate so lexical/title tails cannot hand
  # zero-relevance documents to the consilium while broad questions still retain
  # enough context to answer.
  @spec gate_grounding_hits(String.t(), [hit()]) :: [hit()]
  defp gate_grounding_hits(_query, []), do: []

  defp gate_grounding_hits(query, hits) do
    hits = restrict_to_named_subject_hits(query, hits)
    {scored, unscored} = Enum.split_with(hits, &(hit_relevance(&1) != nil))

    scored_keep =
      case scored do
        [] ->
          []

        _ ->
          top = scored |> Enum.map(&hit_relevance/1) |> Enum.max()
          threshold = if top > 0.0, do: top * @grounding_relative_floor, else: 0.0
          threshold_keep = Enum.filter(scored, &(hit_relevance(&1) >= threshold))

          min_keep =
            scored
            |> Enum.sort_by(&hit_relevance/1, :desc)
            |> Enum.take(@grounding_min_hits)

          keep_ids =
            (threshold_keep ++ min_keep)
            |> Enum.map(&hit_identity/1)
            |> MapSet.new()

          keep = Enum.filter(scored, &(hit_identity(&1) in keep_ids))
          log_grounding_gate(query, scored -- keep, top, threshold)
          keep
      end

    keep_ids = Enum.map(scored_keep ++ unscored, &hit_identity/1) |> MapSet.new()
    Enum.filter(hits, &(hit_identity(&1) in keep_ids))
  end

  defp restrict_to_named_subject_hits(query, hits) do
    case DocumentKind.named_subject_hits(query, hits) do
      [] ->
        hits

      named_hits ->
        named_ids = MapSet.new(named_hits, &hit_identity/1)
        dropped = Enum.reject(hits, &(hit_identity(&1) in named_ids))
        log_named_subject_gate(query, named_hits, dropped)
        named_hits
    end
  end

  defp hit_relevance(hit), do: hit[:relevance]
  defp hit_identity(hit), do: {hit[:type], hit[:key], hit[:id]}

  defp log_named_subject_gate(_query, _named_hits, []), do: :ok

  defp log_named_subject_gate(query, named_hits, dropped) do
    kept =
      named_hits
      |> Enum.map(fn hit -> "#{hit[:type]}:#{hit[:key]}" end)
      |> Enum.join(", ")

    dropped_summary =
      dropped
      |> Enum.map(fn hit -> "#{hit[:type]}:#{hit[:key]}" end)
      |> Enum.join(", ")

    Logger.info(
      "grounding named-subject gate: dropped=#{length(dropped)} " <>
        "query=#{inspect(String.slice(query, 0, 80))} kept=[#{kept}] " <>
        "dropped_hits=[#{dropped_summary}]"
    )
  end

  defp log_grounding_gate(_query, [], _top, _threshold), do: :ok

  defp log_grounding_gate(query, dropped, top, threshold) do
    summary =
      dropped
      |> Enum.map(fn hit ->
        "#{hit[:type]}:#{hit[:key]}@#{Float.round(hit_relevance(hit), 4)}"
      end)
      |> Enum.join(", ")

    Logger.info(
      "grounding gate: dropped=#{length(dropped)} top=#{Float.round(top, 4)} " <>
        "threshold=#{Float.round(threshold, 4)} query=#{inspect(String.slice(query, 0, 80))} " <>
        "hits=[#{summary}]"
    )
  end

  @spec gate_grounding_profile(String.t(), Aggregation.profile(), [hit()]) ::
          Aggregation.profile()
  defp gate_grounding_profile(_query, profile, []), do: profile

  defp gate_grounding_profile(_query, %{facts: [], groups: []} = profile, _hits), do: profile

  defp gate_grounding_profile(query, profile, hits) do
    if Enum.any?(hits, &match?(%{spans: [_ | _]}, &1)) do
      do_gate_grounding_profile(query, profile)
    else
      profile
    end
  end

  defp do_gate_grounding_profile(query, profile) do
    query_tokens = grounding_query_tokens(query)

    groups =
      profile.groups
      |> Enum.filter(&grounding_subject_relevant?(&1.subject, query_tokens))

    facts =
      profile.facts
      |> Enum.filter(&grounding_subject_relevant?(&1.subject, query_tokens))

    log_profile_gate(query, length(profile.facts) - length(facts))

    %{profile | groups: groups, facts: facts, claim_support: claim_support(facts)}
  end

  defp grounding_query_tokens(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2 or MapSet.member?(@grounding_claim_stopwords, &1)))
    |> MapSet.new()
  end

  defp grounding_subject_relevant?(_subject, query_tokens) when map_size(query_tokens) <= 1,
    do: true

  defp grounding_subject_relevant?(subject, query_tokens) do
    subject_tokens =
      subject
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.reject(&MapSet.member?(@grounding_claim_stopwords, &1))
      |> MapSet.new()

    overlap = query_tokens |> MapSet.intersection(subject_tokens) |> MapSet.size()
    overlap >= 2
  end

  defp claim_support([]), do: nil
  defp claim_support(facts), do: facts |> Enum.map(& &1.reliability) |> Enum.max()

  defp log_profile_gate(_query, dropped) when dropped <= 0, do: :ok

  defp log_profile_gate(query, dropped) do
    Logger.info(
      "grounding profile gate: dropped_facts=#{dropped} " <>
        "query=#{inspect(String.slice(query, 0, 80))}"
    )
  end

  # Grounding fed to the consilium: the answer-bearing PASSAGES of each hit (the
  # segmenter's section-prefixed chunk text), not the bare title. A content hit
  # carries `spans`; a title/identity key hit has none → it contributes only its
  # identity line (still useful context, never a fabricated passage). Bounded.
  @spec build_grounding(Aggregation.profile(), [hit()]) :: String.t()
  defp build_grounding(profile, hits) do
    # Facts and passages are budgeted SEPARATELY: facts can't starve the passages
    # (code review), and the passages keep their full budget.
    facts_block = profile |> Aggregation.to_grounding() |> String.slice(0, @facts_char_budget)

    passages =
      hits
      |> Enum.map(&hit_grounding/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> String.slice(0, @grounding_char_budget)

    [facts_block, passages] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
  end

  # Chat-thread epic 2: fold recent conversation history into the grounding, ONLY
  # on the escalate path (an LLM call is already being paid for; the marginal
  # prompt cost is near-free) and ONLY when it's safe to fetch — reuses the ADR-16
  # `Conversations` owner-enforcement predicate exactly, so a `viewer` that doesn't
  # own `conversation_id` (or isn't a real actor uuid — the legacy dual-accept
  # fallback can hand us a plaintext login here) silently yields no history, never
  # an error or a leak. No new no-leak surface: this is the SAME check
  # `GetConversation` already ship-gate-tests.
  @history_turns 6
  @spec prepend_history(String.t(), keyword()) :: String.t()
  defp prepend_history(grounding, opts) do
    case history_block(opts) do
      "" -> grounding
      history -> Enum.join([history, grounding] |> Enum.reject(&(&1 == "")), "\n\n")
    end
  end

  # NOTE: deliberately NOT `Ecto.UUID.cast/1` — it accepts any 16-BYTE string as
  # raw UUID bytes (not just canonical `8-4-4-4-12` hex-dash form), so a plaintext
  # login that happens to be exactly 16 bytes (e.g. "not-a-uuid-login") casts
  # "successfully" and then crashes `Ecto.UUID.dump!/1` downstream in
  # `Conversations` — caught by this epic's own tests. A real actor uuid is
  # ALWAYS canonical form, so a strict format regex is both correct and safe here.
  # (The pre-existing `Conversations.valid_uuid?/1` and `Server.guarded_target/2`
  # share this same cast-based fragility — carded separately, not fixed here:
  # board/todo/conversations-uuid-cast-fragility.md — out of this epic's scope.)
  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @spec valid_actor_uuid?(term()) :: boolean()
  defp valid_actor_uuid?(s), do: is_binary(s) and Regex.match?(@uuid_re, s)

  @spec history_block(keyword()) :: String.t()
  defp history_block(opts) do
    conversation_id = Keyword.get(opts, :conversation_id)
    viewer = Keyword.get(opts, :viewer, "")

    # `verified?` gate (dual-mode-history-leak): fold a conversation's turns ONLY when the viewer was
    # DERIVED from a verified assertion. Under `:dual`, `viewer` can be an attacker-chosen plaintext
    # uuid that satisfies the owner predicate — so requiring verified identity here keeps a foreign
    # conversation unreachable even if `:dual` is enabled (defense-in-depth behind the `:strict` default).
    with true <- is_binary(conversation_id),
         true <- Keyword.get(opts, :verified, false),
         true <- valid_actor_uuid?(viewer),
         {:ok, %{messages: messages}} <- Conversations.get(viewer, conversation_id) do
      text =
        messages
        |> Enum.take(-@history_turns)
        |> Enum.map_join("\n", &"#{&1.role}: #{&1.body}")

      if text == "", do: "", else: "## recent conversation\n" <> text
    else
      _ -> ""
    end
  end

  @spec hit_grounding(hit()) :: String.t()
  defp hit_grounding(%{spans: [_ | _] = spans, type: type, key: key}) do
    passages = spans |> Enum.map_join("\n", & &1.text)
    "## #{type}: #{key}\n#{passages}"
  end

  defp hit_grounding(%{type: type, key: key}), do: "- #{type}: #{key}"

  # A lookup that resolved to nothing — structured, distinct from an error; the
  # queried terms are echoed so the caller/channel can say what was not found.
  defp not_found(query, tier) do
    phrase =
      case query_terms(query) do
        [] -> "your query"
        terms -> "“" <> Enum.join(terms, ", ") <> "”"
      end

    %{
      answer: "I found nothing in the knowledge base for #{phrase}.",
      confidence: 0.3,
      tier: tier,
      status: :not_found,
      citations: []
    }
  end

  # A genuine transport/adapter failure — distinct from not-found, never silent,
  # never a raw error string to the user. The detail is logged for the operator.
  defp error_result(reason, tier) do
    require Logger
    Logger.warning("core: retrieval/synthesis error (#{inspect(reason)})")

    %{
      answer: "The knowledge base could not be reached right now. Please try again.",
      confidence: 0.0,
      tier: tier,
      status: :error,
      citations: []
    }
  end

  defp query_terms(query), do: query |> patterns() |> Enum.map(&String.trim(&1, "%"))

  defp cite(hit) do
    %{source: hit.type, ref: hit.key, confidence: hit.score}
    |> maybe_put_citation_url(Map.get(hit, :source_ref))
  end

  defp maybe_put_citation_url(citation, source_ref) when is_binary(source_ref) do
    case citation_url(source_ref) do
      nil -> citation
      url -> Map.put(citation, :url, url)
    end
  end

  defp maybe_put_citation_url(citation, _source_ref), do: citation

  defp citation_url(source_ref) do
    with [kind, id] <- String.split(source_ref, ":", parts: 2),
         true <- String.trim(id) != "",
         template when is_binary(template) <- citation_template(kind),
         true <- String.contains?(template, "{id}"),
         url <- String.replace(template, "{id}", URI.encode_www_form(id)),
         true <- valid_citation_url?(url) do
      url
    else
      _ -> nil
    end
  end

  defp valid_citation_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  defp citation_template(kind) do
    :swarm
    |> Application.get_env(:citation_url_templates, %{})
    |> Map.get(kind)
  end

  # A claim-graph fact as a citation: source "claim", the S-P-O as the ref, the
  # edge reliability as confidence — so a fact-grounded answer is explainable.
  @spec fact_cite(Aggregation.fact()) :: citation()
  defp fact_cite(f) do
    %{source: "claim", ref: "#{f.subject} #{f.predicate} #{f.object}", confidence: f.reliability}
  end

  # Significant query terms → ILIKE patterns (drop stopwords and short tokens).
  @spec patterns(String.t()) :: [String.t()]
  defp patterns(query) do
    query
    |> String.downcase()
    |> String.split(~r/\W+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or &1 in @stopwords))
    |> Enum.uniq()
    |> Enum.map(&"%#{&1}%")
  end
end
