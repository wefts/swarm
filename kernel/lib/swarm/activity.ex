defmodule Swarm.Activity do
  @moduledoc """
  Polled, scope-safe worker/job activity log (swarm ADR-15) — the "what it did"
  surface for the dashboard. Read-only projection over the transactional `outbox`
  (the thin dispatch slice available now); the rich ER/enrichment-outcome sources
  attach here when the cognitive loop runs (see "Sources", assert-skipped in tests).

  Poll, not stream: the channel polls with an **opaque cursor** (`Activity.Cursor`)
  and gets a `next_cursor` to resume. `"" ⇒ most recent`.

  ## No-leak (the kernel is the scope authority)

    * The raw `payload`, `target_key`, node `key` and `seq` **never** reach the
      wire. Each event's referenced subject scope is resolved (`node.scope` /
      `edge.visibility_scope`, joined in SQL) and an out-of-scope event is
      **dropped** — not redacted (a placeholder would itself disclose
      private-activity volume).
    * `subject_type` is emitted only for an in-scope node subject; `count` would
      aggregate in-scope subjects only (the thin slice emits single events,
      `count: 0`).
    * **Gap non-inferability (the council headline).** The skip of out-of-scope
      rows happens entirely server-side in one query, and the cursor advances by
      *visible* events, never by a fixed "scan budget". So neither cursor deltas
      (the cursor is opaque) **nor poll count** reveal hidden-event volume: a full
      page resumes at the last delivered visible `seq`; a partial page (caught up)
      resumes at the opaque tail in a single poll, so a long run of hidden rows is
      crossed in one request, not counted out in budget-sized polls. The opaque
      cursor also hides `max_seq` itself (the total event count, hidden included).

  ## Sources

    * `outbox` (`seq, change, target_key, inserted_at`) — the thin dispatch slice,
      present now: ingest/graph writes (`node_added`, `edge_reinforced`,
      `merge_refused`, `node_merged`, `content_added`).
    * `entity_resolution_audit`, `enrichment_decision`/`enrichment_pass` — rich
      worker outcomes (`entity_resolution`, `enrichment`); populated only once the
      loop runs, so they are wired into the kind vocabulary but assert-skipped.

  ## Cost

  A poll runs one indexed forward (or, for `""`, backward) scan that the database
  stops at `limit` in-scope rows. The no-leak guarantee precludes a per-poll seq
  ceiling (that is exactly the poll-count leak), so a viewer whose visible events
  are sparse among many hidden ones makes the database scan past the hidden run
  within that single query. On this low-volume operator surface that is cheap; at
  scale the privacy-preserving bound is a per-viewer server-side scan checkpoint,
  not a wire-visible budget (a follow-up if the loop makes the outbox large).
  """

  alias Swarm.Activity.Cursor
  alias Swarm.{Config, Repo}

  @type event :: %{
          kind: String.t(),
          at: String.t(),
          subject_type: String.t(),
          outcome: String.t(),
          count: integer()
        }
  @type page :: %{status: :found | :not_found, events: [event()], next_cursor: String.t()}

  # The closed kind set the thin outbox slice can emit now. Rich loop kinds
  # ("entity_resolution", "enrichment") join this set when those sources attach.
  @outbox_kinds ~w(node_added edge_reinforced merge_refused node_merged content_added)

  # Only well-formed "node:<int>" / "edge:<int>" subjects are resolvable; the guard
  # keeps the id::bigint cast in the scope join total over any row shape.
  @subject_re "^(node|edge):[0-9]+$"

  @doc "The closed event-kind set currently emittable (the `kinds` filter vocabulary)."
  @spec kinds() :: [String.t()]
  def kinds, do: @outbox_kinds

  @doc """
  One poll. `opts`: `:scopes` (allowed visibility scopes, default-deny — empty ⇒
  no visible events), `:cursor` (opaque; `""` ⇒ most recent), `:limit` (clamped to
  `[1, max_limit]`, `0` ⇒ default), `:kinds` (filter; empty ⇒ all). Returns a
  `page()` whose `events` are already scope-filtered and ordered oldest→newest.
  """
  @spec feed(keyword()) :: page()
  def feed(opts \\ []) do
    scopes = Keyword.get(opts, :scopes, [])
    kinds = Keyword.get(opts, :kinds, [])
    cursor = Keyword.get(opts, :cursor, "")
    cfg = Config.activity_feed()
    limit = clamp(Keyword.get(opts, :limit, 0), cfg.default_limit, cfg.max_limit)

    cond do
      # Default-deny: an empty scope set sees nothing (and reveals no position).
      scopes == [] ->
        %{status: :not_found, events: [], next_cursor: cursor}

      cursor == "" ->
        recent_page(scopes, kinds, limit)

      true ->
        case Cursor.decode(cursor) do
          {:ok, after_seq} -> forward_page(after_seq, scopes, kinds, limit)
          # Tampered / wrong-key / rotated cursor ⇒ resync to the tail, never crash.
          :error -> recent_page(scopes, kinds, limit)
        end
    end
  end

  # "" ⇒ most recent: the newest `limit` in-scope events (scanned backward in SQL,
  # returned oldest→newest); next_cursor = the opaque tail, so the next poll follows
  # forward. We do not page backward through history (a thin-slice limitation).
  @spec recent_page([String.t()], [String.t()], pos_integer()) :: page()
  defp recent_page(scopes, kinds, limit) do
    # Capture the tail FIRST and bound the scan by it, so next_cursor = that same
    # tail can never skip an event that appended after the scan (a lost-event race).
    tail = max_seq()

    events =
      scopes
      |> scan(kinds, limit, :desc, nil, tail)
      |> Enum.reverse()
      |> Enum.map(&to_event/1)

    %{status: status(events), events: events, next_cursor: Cursor.encode(tail)}
  end

  # A resume poll: the next `limit` in-scope events with seq > after_seq (forward).
  # A FULL page resumes at the last delivered visible seq (so cadence tracks visible
  # volume only); a SHORT page means we reached the tail, so we resume at the opaque
  # tail — crossing any trailing hidden run in this one poll, never counted out.
  @spec forward_page(non_neg_integer(), [String.t()], [String.t()], pos_integer()) :: page()
  defp forward_page(after_seq, scopes, kinds, limit) do
    # Snapshot the tail BEFORE scanning and bound the scan by it. A FULL page resumes
    # at the last delivered visible seq; a SHORT page (exhausted to `tail`) resumes at
    # `tail` — never a later max_seq(), so an event appended mid-poll is not skipped.
    tail = max_seq()
    rows = scan(scopes, kinds, limit, :asc, after_seq, tail)
    events = Enum.map(rows, &to_event/1)

    next =
      if length(rows) == limit do
        rows |> List.last() |> hd()
      else
        tail
      end

    %{status: status(events), events: events, next_cursor: Cursor.encode(next)}
  end

  # One scope/kind-pushed-down scan. The database resolves each outbox row's subject
  # scope (node.scope / edge.visibility_scope) by joining on the parsed id and keeps
  # only in-scope rows, stopping at `limit` — so out-of-scope rows are skipped
  # server-side and never influence the cursor. Returns raw rows
  # [seq, change, inserted_at, node_type | nil].
  @spec scan(
          [String.t()],
          [String.t()],
          pos_integer(),
          :asc | :desc,
          non_neg_integer() | nil,
          non_neg_integer()
        ) :: [list()]
  defp scan(scopes, kinds, limit, order, after_seq, tail) do
    # $1 scopes, $2 limit, $3 tail (the snapshot upper bound) are always present; the
    # lower seq bound and the kind filter are appended positionally when set, so the
    # SQL only references params that exist.
    {seq_clause, params} =
      case after_seq do
        nil -> {"", [scopes, limit, tail]}
        s -> {"AND o.seq > $4", [scopes, limit, tail, s]}
      end

    {kind_clause, params} =
      case kinds do
        [] -> {"", params}
        ks -> {"AND o.change = ANY($#{length(params) + 1}::text[])", params ++ [ks]}
      end

    dir = if order == :desc, do: "DESC", else: "ASC"

    %{rows: rows} =
      Repo.query!(
        """
        SELECT o.seq, o.change, o.inserted_at, n.type
          FROM outbox o
          LEFT JOIN node n
            ON o.target_key LIKE 'node:%' AND n.id = substring(o.target_key from 6)::bigint
          LEFT JOIN edge e
            ON o.target_key LIKE 'edge:%' AND e.id = substring(o.target_key from 6)::bigint
         WHERE o.target_key ~ '#{@subject_re}'
           AND o.seq <= $3
           #{seq_clause}
           AND (
                 (n.id IS NOT NULL AND n.scope = ANY($1::text[]))
              OR (e.id IS NOT NULL AND e.visibility_scope = ANY($1::text[]))
               )
           #{kind_clause}
         ORDER BY o.seq #{dir}
         LIMIT $2
        """,
        params
      )

    rows
  end

  @spec to_event(list()) :: event()
  defp to_event([_seq, change, at, node_type]) do
    %{
      kind: change,
      at: iso(at),
      subject_type: node_type || "",
      outcome: outcome(change),
      count: 0
    }
  end

  @spec status([event()]) :: :found | :not_found
  defp status([]), do: :not_found
  defp status(_), do: :found

  @spec max_seq() :: non_neg_integer()
  defp max_seq do
    %{rows: [[m]]} = Repo.query!("SELECT COALESCE(MAX(seq), 0) FROM outbox", [])
    m
  end

  @spec outcome(String.t()) :: String.t()
  defp outcome("node_merged"), do: "merged"
  defp outcome("merge_refused"), do: "refused"
  defp outcome(_), do: ""

  # 0/absent ⇒ default; else clamp into [1, max]. (uint32 0 means "unset" on the wire.)
  @spec clamp(integer(), pos_integer(), pos_integer()) :: pos_integer()
  defp clamp(v, default, _max) when not is_integer(v) or v <= 0, do: default
  defp clamp(v, _default, max) when v > max, do: max
  defp clamp(v, _default, _max), do: v

  @spec iso(term()) :: String.t()
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso(other), do: to_string(other)
end
