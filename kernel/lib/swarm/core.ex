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

  alias Swarm.{Consilium, Gate, Repo}

  @default_scopes ["public"]
  @search_limit 10
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
          answer: String.t(),
          confidence: float(),
          tier: String.t(),
          status: status(),
          citations: [citation()]
        }
  @type hit :: %{id: integer(), type: String.t(), key: String.t(), score: float()}
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
    {:ok, search(query, scopes, opts)}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:retrieval_failed, Exception.message(e)}}
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

        synthesize(query, hits, base_status, opts)
    end
  end

  defp synthesize(query, hits, base_status, opts) do
    grounding = Enum.map_join(hits, "\n", fn h -> "- #{h.type}: #{h.key}" end)

    case Consilium.deliberate(query, Keyword.put(opts, :grounding, grounding)) do
      {:ok, verdict} ->
        %{
          answer: verdict.answer,
          confidence: verdict.confidence,
          tier: "escalate",
          status: base_status,
          citations: Enum.map(hits, &cite/1)
        }

      {:error, reason} ->
        # Fail-loud: a synthesis failure is an ERROR (distinct from not-found),
        # quarantined low-confidence, never raw panel text. Reason logged, not leaked.
        error_result({:escalation_failed, reason}, "escalate")
    end
  end

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
