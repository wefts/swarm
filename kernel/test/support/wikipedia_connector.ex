defmodule Swarm.Test.WikipediaConnector do
  @moduledoc """
  A **public** reference connector for the MediaWiki API (swarm ADR-5), used to
  drive the first live vertical slice on real data — Wikipedia — without any
  secrets. It is a reference *adapter*, not kernel code: it lives in `test/support`
  exactly like `Swarm.Test.HostileConnector`, the kernel never imports it, and
  `Swarm.Connector.Sync.run/2` drives it by module at runtime.

  Ported from the glpi-agent `src/agent/kb/wiki.py` prototype: the `allpages`
  generator + `continue`-token pagination, the wikitext markup strip, and the
  internal-link extraction. The shapes are adapted to the kernel's `fetch/2`
  contract and the `Swarm.Ingest` event map.

  ## What it emits

  Each source page becomes one ingest event:

      %{
        provenance: "wikipedia:en:<pageid>",   # evidential origin = page id, stable
        occurred_at: <revision timestamp, UTC>,
        entities: [
          %{type: "article", key: <canonical title>, scope: "public", content: ""},
          # one stub per distinct internal link target:
          %{type: "article", key: <canonical target>, scope: "public", content: ""},
          ...
        ],
        relations: [%{from: <canonical title>, to: <canonical target>, type: "links_to"}, ...]
      }

  The link target is a **stub** node (same `(type, key)` identity as the target's
  own page); when that page is later ingested, the idempotent upsert resolves both
  to the one node — *iff* the title canonicalisation matches. That canonicalisation
  (`canonical_title/1`) is the connector's entity-resolution surface and the first
  place real-data fragmentation shows up (the architect-consilium's risk #1).

  ## `fetch/2` cursor

  The cursor is `:start`, then a map `%{"__page" => n, <continue params>}`, then
  `:done`. `opts`:

  - `:base_url` — API endpoint (default English Wikipedia).
  - `:gaplimit` — pages per API call (default 10).
  - `:max_pages` — stop after N API pages; if the source still has a `continue`
    token when we stop, the final page is flagged `truncated?: true` so the Sync
    report records the slice as incomplete (no silent cap). `nil` = exhaust.
  - `:scope` — node/edge scope (default `"public"`).
  - `:http` — injectable `(url :: String.t() -> {:ok, body} | {:error, term})`;
    defaults to a real `:httpc` GET. Tests pass a fixture function (no network).
  """

  @behaviour Swarm.Ports.Connector

  @default_base "https://en.wikipedia.org/w/api.php"
  @user_agent "swarm-kernel-wikipedia-slice/0.1 (https://github.com/wefts; local research)"

  # MediaWiki namespaces whose link targets are NOT main-namespace articles.
  @nonarticle_prefixes ~w(
    file image fichier category template help wikipedia portal
    user talk special media mediawiki module book draft timedtext
    wikt en simple commons
  )

  @impl true
  def describe,
    do: %{name: "wikipedia", kind: :connector, source: "mediawiki", sync_modes: [:full]}

  @impl true
  def fetch(:start, opts), do: fetch(%{"__page" => 1}, opts)

  def fetch(cursor, opts) when is_map(cursor) do
    {page_num, continue} = Map.pop(cursor, "__page", 1)
    scope = Keyword.get(opts, :scope, "public")
    http = Keyword.get(opts, :http, &http_get/1)

    with {:ok, body} <- http.(url(continue, opts)),
         {:ok, json} <- decode(body) do
      events = json |> pages(json) |> Enum.map(&to_event(&1, scope))
      {:ok, paginate(events, json, page_num, opts)}
    end
  end

  # --- pagination ------------------------------------------------------------

  # Decide the next cursor + truncation from the API's `continue` token and our
  # own `:max_pages` ceiling. A ceiling hit while the source still has more is a
  # surfaced truncation (swarm ADR-5/ADR-9), never a silent cap.
  defp paginate(events, json, page_num, opts) do
    cont = Map.get(json, "continue")
    max_pages = Keyword.get(opts, :max_pages)

    cond do
      is_nil(cont) ->
        %{events: events, cursor: :done, truncated?: false}

      is_integer(max_pages) and page_num >= max_pages ->
        %{events: events, cursor: :done, truncated?: true}

      true ->
        next = cont |> stringify() |> Map.put("__page", page_num + 1)
        %{events: events, cursor: next, truncated?: false}
    end
  end

  # --- request ---------------------------------------------------------------

  defp url(continue, opts) do
    base = Keyword.get(opts, :base_url, @default_base)
    gaplimit = Keyword.get(opts, :gaplimit, 10)

    params =
      %{
        "action" => "query",
        "generator" => "allpages",
        "gapnamespace" => "0",
        "gaplimit" => to_string(gaplimit),
        "gapfilterredir" => "nonredirects",
        "prop" => "revisions|info",
        "rvprop" => "content|timestamp",
        "rvslots" => "main",
        "inprop" => "url",
        "format" => "json",
        "formatversion" => "2"
      }
      |> Map.merge(stringify(continue))

    base <> "?" <> URI.encode_query(params)
  end

  # Drop our internal "__page" bookkeeping key before it reaches the API.
  defp stringify(map) when is_map(map) do
    map
    |> Map.delete("__page")
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp http_get(url) do
    ensure_started()

    headers = [{~c"user-agent", String.to_charlist(@user_agent)}]
    http_opts = [ssl: ssl_opts(), timeout: 30_000, connect_timeout: 15_000]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, body}} -> {:ok, body}
      {:ok, {{_v, status, _r}, _h, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:http, reason}}
    end
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} when is_map(json) -> {:ok, json}
      {:ok, _} -> {:error, :unexpected_json}
      {:error, reason} -> {:error, {:bad_json, reason}}
    end
  end

  # --- page → event ----------------------------------------------------------

  # formatversion=2 returns query.pages as a LIST; v1 returns a map keyed by id.
  defp pages(_json, %{"query" => %{"pages" => pages}}) when is_list(pages), do: pages
  defp pages(_json, %{"query" => %{"pages" => pages}}) when is_map(pages), do: Map.values(pages)
  defp pages(_json, _), do: []

  defp to_event(page, scope) do
    title = canonical_title(Map.get(page, "title", ""))
    pageid = Map.get(page, "pageid", Map.get(page, "title"))
    wikitext = wikitext(page)

    targets =
      wikitext
      |> link_targets()
      |> Enum.reject(&(&1 == "" or &1 == title))
      |> Enum.uniq()

    page_entity = %{type: "article", key: title, scope: scope, content: ""}
    stubs = Enum.map(targets, &%{type: "article", key: &1, scope: scope, content: ""})
    relations = Enum.map(targets, &%{from: title, to: &1, type: "links_to"})

    %{
      provenance: "wikipedia:en:#{pageid}",
      occurred_at: occurred_at(page),
      entities: [page_entity | stubs],
      relations: relations
    }
  end

  defp wikitext(page) do
    case get_in(page, ["revisions"]) do
      [rev | _] -> get_in(rev, ["slots", "main", "content"]) || Map.get(rev, "content") || ""
      _ -> ""
    end
  end

  # Revision timestamp is ISO-8601 with a `Z` offset (tz-aware); the ingest
  # boundary accepts that string directly. Fall back to a stable epoch only if a
  # page somehow lacks a revision timestamp (still tz-aware, never naive).
  defp occurred_at(page) do
    case get_in(page, ["revisions"]) do
      [%{"timestamp" => ts} | _] when is_binary(ts) -> ts
      _ -> "1970-01-01T00:00:00Z"
    end
  end

  # --- wikitext: link extraction + canonicalisation --------------------------

  @wikilink ~r/\[\[([^\]\|]+)(?:\|[^\]]*)?\]\]/u

  @doc """
  Extract canonical internal-link targets from raw wikitext. Skips non-article
  namespaces and anchors; canonicalises each to the page-title form so a link and
  its target page share one node identity.
  """
  @spec link_targets(String.t()) :: [String.t()]
  def link_targets(wikitext) when is_binary(wikitext) do
    @wikilink
    |> Regex.scan(wikitext, capture: :all_but_first)
    |> Enum.map(fn [target | _] -> target end)
    |> Enum.reject(&nonarticle?/1)
    |> Enum.map(&canonical_title/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp nonarticle?(target) do
    case String.split(target, ":", parts: 2) do
      [prefix, _rest] -> String.downcase(String.trim(prefix)) in @nonarticle_prefixes
      _ -> false
    end
  end

  @doc """
  Canonicalise a MediaWiki title to its page-identity form: **URL-decode** (a link
  target may arrive percent-encoded — `%21%21%21 (album)` → `!!! (album)`; swarm
  ADR-13 layer 1), drop the `#anchor`, turn underscores into spaces, collapse runs
  of whitespace, trim, and uppercase the first character (MediaWiki titles are
  first-letter-case-insensitive). `URI.decode/1` leaves a lone `%` untouched, so a
  legitimate `100% (song)` is not falsely rewritten.

  This is the connector's source-normalisation layer. It does NOT resolve aliases
  or redirects (internal-case variants the source treats as one page) — that is the
  kernel alias seam (swarm ADR-13 layer 2, `board/todo/entity-resolution`), still a
  KNOWN-GAP and a frozen fixture.
  """
  @spec canonical_title(String.t()) :: String.t()
  def canonical_title(title) when is_binary(title) do
    title
    |> URI.decode()
    |> String.split("#", parts: 2)
    |> hd()
    |> String.replace("_", " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> upcase_first()
  end

  defp upcase_first(""), do: ""

  defp upcase_first(s) do
    {first, rest} = String.split_at(s, 1)
    String.upcase(first) <> rest
  end
end
