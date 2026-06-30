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

  alias Swarm.{Activity, Consilium, Deliberation, Gate, Repo}
  alias Swarm.Graph.{Claims, Neighborhood, Retrieval}

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
  @type citation :: %{source: String.t(), ref: String.t(), confidence: float()}
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
          optional(:relevance) => float()
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
    if first_person and viewer == "" do
      identity_required()
    else
      # "my X" with an asker → narrow retrieval to that asker's items.
      owner = if first_person, do: viewer, else: nil

      decision = Gate.route(query, opts)

      case decision.tier do
        :tier0 -> tier0_answer(decision.intent)
        :tier_tools -> tools_answer(query, scopes, retriever, owner)
        :escalate -> escalate_answer(query, scopes, retriever, owner, opts)
      end
    end
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
    key_hits = query |> search(scopes, opts) |> gate_key_hits(query)

    if owner do
      key_hits
    else
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
            relevance: &1.relevance
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
    {"SELECT id, type, key FROM node WHERE scope = ANY($1) AND key ILIKE ANY($2) ORDER BY key LIMIT $3",
     [scopes, pats, limit]}
  end

  defp search_sql(scopes, pats, limit, owner) do
    {"SELECT id, type, key FROM node WHERE scope = ANY($1) AND key ILIKE ANY($2) AND key ~* $4 ORDER BY key LIMIT $3",
     [scopes, pats, limit, owner_boundary(owner)]}
  end

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

  defp tools_answer(query, scopes, retriever, owner) do
    case retriever.(query, scopes, limit: @search_limit, owner: owner) do
      {:ok, []} ->
        not_found(query, "tier_tools")

      {:ok, hits} ->
        %{
          answer: "Found #{length(hits)} matching item(s) in the knowledge base.",
          confidence: 0.7,
          tier: "tier_tools",
          status: :found,
          citations: Enum.map(hits, &cite/1)
        }

      {:partial, hits, failed} ->
        %{
          answer:
            "Partial results — #{length(hits)} item(s); #{length(failed)} source(s) unavailable.",
          confidence: 0.5,
          tier: "tier_tools",
          status: :partial,
          citations: Enum.map(hits, &cite/1)
        }

      {:error, reason} ->
        error_result(reason, "tier_tools")
    end
  end

  defp escalate_answer(query, scopes, retriever, owner, opts) do
    case retriever.(query, scopes, limit: @search_limit, owner: owner) do
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

  defp synthesize(query, hits, base_status, scopes, opts) do
    # Claim-aware: surface enrichment claim-graph facts about the query's entities
    # (scope-enforced) so a precise value answers directly, not only if a chunk lands.
    facts = Claims.for_query(query, scopes)
    grounding = build_grounding(facts, hits)

    case Consilium.deliberate(query, Keyword.put(opts, :grounding, grounding)) do
      {:ok, verdict} ->
        # Retain the panel-vs-judge verdict (ADR-15) so the answer can re-open its
        # deliberation — only for a non-anonymous asker, under the asking scopes; a
        # single insert AFTER the LLM returned. "" when not retained.
        viewer = Keyword.get(opts, :viewer, "")
        ask_ref = Deliberation.maybe_persist(verdict, viewer, scopes)
        calibrated_answer(query, verdict, hits, facts, base_status, ask_ref)

      {:error, reason} ->
        # Fail-loud: a synthesis failure is an ERROR (distinct from not-found),
        # quarantined low-confidence, never raw panel text. Reason logged, not leaked.
        error_result({:escalation_failed, reason}, "escalate")
    end
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

  @spec calibrated_answer(
          String.t(),
          Consilium.verdict(),
          [hit()],
          [Claims.fact()],
          status(),
          String.t()
        ) :: answer()
  defp calibrated_answer(query, verdict, hits, facts, base_status, ask_ref) do
    if verdict.supported do
      %{
        answer: verdict.answer,
        confidence: calibrate_confidence(verdict.confidence, verdict.disagreement, hits),
        tier: "escalate",
        status: base_status,
        # Cite both the retrieved passages AND the claim facts that grounded the
        # answer — so a claim-only answer (no retrieval hits) is still explainable.
        citations: Enum.map(hits, &cite/1) ++ Enum.map(facts, &fact_cite/1),
        ask_ref: ask_ref
      }
    else
      # The judge marked the answer NOT grounded (an abstention) — honest `:not_found`,
      # confidence 0.0, the standard not-found message (NOT the judge's "it's not in the
      # text" prose), no citations (we don't present examined pages as support). The
      # deliberation is still retained, so the dashboard can show that it deliberated.
      query
      |> not_found("escalate")
      |> Map.merge(%{confidence: 0.0, ask_ref: ask_ref})
    end
  end

  # final = judge_confidence · agreement · retrieval_cap, clamped to [0,1].
  @spec calibrate_confidence(float(), float(), [hit()]) :: float()
  defp calibrate_confidence(judge_conf, disagreement, hits) do
    agreement = 1.0 - 0.5 * disagreement
    clamp01(judge_conf * agreement * retrieval_cap(hits))
  end

  # Retrieval relevance as a ONE-SIDED cap, not a scalar (council): at/above the
  # "good in-scope" target it is 1.0 (a strong answer is NOT penalised → confidence ≈
  # judge·agreement); only marginal grounding (floor-band) caps it, and never below
  # 0.6 so a vocabulary-mismatch / multi-source answer is not crushed. Uses the BEST
  # supporting relevance; no dense signal (identity/lexical hits) ⇒ no cap.
  # STEP-2 interface note: the entity-aggregation layer synthesises across many
  # mid-relevance sources — it should pass a corroboration/aggregate signal here so
  # the per-span max does not under-score a well-corroborated synthesis.
  @spec retrieval_cap([hit()]) :: float()
  defp retrieval_cap(hits) do
    case Enum.flat_map(hits, fn h -> List.wrap(h[:relevance]) end) do
      [] -> 1.0
      rels -> ramp(Enum.max(rels))
    end
  end

  @spec ramp(float()) :: float()
  defp ramp(x) when x >= @relevance_full, do: 1.0
  defp ramp(x) when x <= @relevance_floor, do: 0.6
  defp ramp(x), do: 0.6 + 0.4 * (x - @relevance_floor) / (@relevance_full - @relevance_floor)

  @spec clamp01(float()) :: float()
  defp clamp01(x), do: x |> max(0.0) |> min(1.0)

  # Grounding fed to the consilium: the answer-bearing PASSAGES of each hit (the
  # segmenter's section-prefixed chunk text), not the bare title. A content hit
  # carries `spans`; a title/identity key hit has none → it contributes only its
  # identity line (still useful context, never a fabricated passage). Bounded.
  @spec build_grounding([Claims.fact()], [hit()]) :: String.t()
  defp build_grounding(facts, hits) do
    # Facts and passages are budgeted SEPARATELY: facts can't starve the passages
    # (code review), and the passages keep their full budget.
    facts_block = facts |> Claims.to_grounding() |> String.slice(0, @facts_char_budget)

    passages =
      hits
      |> Enum.map(&hit_grounding/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> String.slice(0, @grounding_char_budget)

    [facts_block, passages] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
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

  defp cite(hit), do: %{source: hit.type, ref: hit.key, confidence: hit.score}

  # A claim-graph fact as a citation: source "claim", the S-P-O as the ref, the
  # edge reliability as confidence — so a fact-grounded answer is explainable.
  @spec fact_cite(Claims.fact()) :: citation()
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
