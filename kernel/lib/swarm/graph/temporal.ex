defmodule Swarm.Graph.Temporal do
  @moduledoc """
  Bitemporal validity of graph facts (`docs/design/temporal-fact-model.md`, schema v13).

  An `edge` is the timeless identity of a fact; this module records WHEN the fact was true
  according to its source (valid time) apart from when Swarm learned it (transaction time), in
  the `edge_validity` table. Which relations are timed at all — and how a newer fact closes an
  older one — is declared by the governed relation registry (`Swarm.WorldMap.Domain.temporal/1`),
  never decided per fact by an extractor.

  ## Rules (write side, all inside the caller's ingest transaction)

  - Only `:state` relations get intervals. `:event` / `:invariant` / ungoverned relations are a
    no-op here (`{:ok, :untimed}`).
  - A DATED assertion at `t` (a live API observation, a commit time, …) opens `[t, ∞)` for the
    edge, or advances `observed_at` on the already-open interval — the fact's identity is
    unchanged, its validity is re-attested. It then CLOSES every other open interval on the same
    supersession key at `t` (`superseded`): an undated one unconditionally, a dated one only if it
    started at or before `t`.
  - A LATE-ARRIVING dated assertion (some open dated interval on the key started AFTER `t`) is
    recorded as history — a CLOSED interval `[t, next_start)` — and never touches current state.
  - An UNDATED assertion (no honest source time) opens an unknown-start interval
    (`valid_from = observed_at = NULL`) and never closes anything: it cannot supersede a dated fact.
  - `reconcile_absent/3` closes what a live source stopped returning: `valid_to` is the LAST
    instant the fact was observed true (nothing is asserted past the evidence), the run instant is
    kept as `absent_at`. Callers gate it on a COMPLETE run — a failed fetch must never read as
    mass disappearance.

  Concurrency: a transactional advisory lock on the supersession key serialises writers to the
  same logical state (two jobs seeing `vm → A` and `vm → B` would otherwise lock edge rows in
  opposite order and deadlock on each other's validity rows — Gemini critique 2026-09-03). The DB
  additionally enforces non-overlap per `(edge, source)` with an exclusion constraint.

  Reads distinguish "what is X now?" (`current/3`) from "what happened to X?" (`history/3`);
  `check/4` answers whether one concrete claim is still current. Legacy edges with no interval
  rows read as UNDATED candidates — nothing is retroactively timed. Reads are scope-filtered when
  `:scopes` is given; unscoped reads are operator/proof tooling, never a serve path.
  """

  alias Swarm.Repo
  alias Swarm.WorldMap.Domain

  require Logger

  @type fact :: %{
          edge_id: integer(),
          subject: String.t(),
          relation: String.t(),
          object: String.t(),
          scope: String.t(),
          interval_id: integer() | nil,
          valid_from: DateTime.t() | nil,
          valid_to: DateTime.t() | nil,
          observed_at: DateTime.t() | nil,
          dated?: boolean(),
          source: String.t() | nil,
          closed_reason: String.t() | nil,
          absent_at: DateTime.t() | nil
        }

  # --- write side ------------------------------------------------------------------------------

  @doc """
  Record that `edge_id` was asserted by `:source` (a site-qualified run identity such as
  `proxmox:casa`) at `:valid_time` (a UTC `DateTime`, or `nil` for an undated assertion), with
  optional `:origin`. Returns `{:ok, :untimed | :opened | :extended | :historical | :undated}` or
  `{:error, reason}`. Call inside the ingest transaction, after the edge upsert.
  """
  @spec assert(integer(), keyword()) :: {:ok, atom()} | {:error, term()}
  def assert(edge_id, opts) when is_integer(edge_id) do
    source = Keyword.fetch!(opts, :source)
    valid_time = Keyword.get(opts, :valid_time)
    origin = Keyword.get(opts, :origin)

    case edge_row(edge_id) do
      nil ->
        {:error, {:unknown_edge, edge_id}}

      edge ->
        case Domain.temporal(edge.type) do
          %{kind: :state, supersession: supersession} ->
            key = supersession_key(edge, supersession)
            lock!(key)
            assert_state(edge, key, valid_time, source, origin)

          _ ->
            {:ok, :untimed}
        end
    end
  end

  @doc """
  Close, as absent, every open interval asserted by `source` that this run did not re-attest
  (`updated_at < run_started_at`). `as_of` is the run's observation instant, recorded as
  `absent_at`; `valid_to` is the interval's own last `observed_at` (or `as_of` for an undated
  row, which has no better evidence). Returns `{:ok, closed_count}`.

  Only call after a COMPLETE run (`report.complete?`); an incomplete run's absences are unknowns.
  """
  @spec reconcile_absent(String.t(), DateTime.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  def reconcile_absent(source, %DateTime{} = run_started_at, %DateTime{} = as_of)
      when is_binary(source) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE edge_validity
           SET valid_to = coalesce(observed_at, $3),
               closed_reason = 'absent',
               absent_at = $3,
               closed_at = now(),
               updated_at = now()
         WHERE source = $1
           AND valid_to IS NULL
           AND updated_at < $2
        """,
        [source, run_started_at, as_of]
      )

    if n > 0, do: Logger.info("temporal: #{source} closed #{n} interval(s) as absent")
    {:ok, n}
  end

  # --- read side -------------------------------------------------------------------------------

  @doc """
  The facts `subject relation ?` that are CURRENT at `:at` (default now). If any DATED interval
  covers the instant only dated facts are returned; otherwise undated ones (explicit unknown-start
  intervals and legacy interval-less edges) are returned flagged `dated?: false` — they may answer,
  with lower temporal confidence. `:scopes` filters edge and endpoint scopes.
  """
  @spec current(String.t(), String.t(), keyword()) :: [fact()]
  def current(subject_key, relation, opts \\ []) do
    at = Keyword.get(opts, :at) || DateTime.utc_now()

    {scope_sql, params} = scope_clause(Keyword.get(opts, :scopes), 4)

    rows =
      Repo.query!(
        facts_sql(
          """
          AND (v.id IS NULL
               OR ((v.valid_from IS NULL OR v.valid_from <= $3)
                   AND (v.valid_to IS NULL OR v.valid_to > $3)))
          """ <> scope_sql,
          "ORDER BY v.observed_at DESC NULLS LAST, d.key"
        ),
        [subject_key, relation, at | params]
      ).rows

    facts = Enum.map(rows, &row_to_fact/1)

    case Enum.filter(facts, & &1.dated?) do
      [] -> facts
      dated -> dated
    end
  end

  @doc """
  Every recorded interval for `subject relation ?`, oldest first (unknown starts first), plus
  legacy interval-less edges as undated entries. This is the "what happened to X?" view; it
  returns DIFFERENT results from `current/3` on the same data once anything has been superseded.
  """
  @spec history(String.t(), String.t(), keyword()) :: [fact()]
  def history(subject_key, relation, opts \\ []) do
    {scope_sql, params} = scope_clause(Keyword.get(opts, :scopes), 3)

    Repo.query!(
      facts_sql(
        scope_sql,
        "ORDER BY v.valid_from ASC NULLS FIRST, v.valid_to ASC NULLS LAST, d.key"
      ),
      [subject_key, relation | params]
    ).rows
    |> Enum.map(&row_to_fact/1)
  end

  @doc """
  Is the concrete claim `subject relation object` still true at `:at`? Returns
  `%{status: status, fact: fact | nil, current: [fact]}` where status is

  - `:current` — a dated interval covers the instant;
  - `:undated` — only undated evidence (the claim may hold; no dated fact contradicts it);
  - `:superseded` — the claim has history but a different dated fact is current now;
  - `:closed` — the claim was true and closed (absent) with nothing current in its place;
  - `:unknown` — the graph holds no such claim.
  """
  @spec check(String.t(), String.t(), String.t(), keyword()) :: %{
          status: :current | :undated | :superseded | :closed | :unknown,
          fact: fact() | nil,
          current: [fact()]
        }
  def check(subject_key, relation, object_key, opts \\ []) do
    now = current(subject_key, relation, opts)
    past = history(subject_key, relation, opts)
    mine_now = Enum.filter(now, &(&1.object == object_key))
    mine_past = Enum.filter(past, &(&1.object == object_key))

    cond do
      match?([%{dated?: true} | _], mine_now) ->
        %{status: :current, fact: hd(mine_now), current: now}

      mine_now != [] ->
        %{status: :undated, fact: hd(mine_now), current: now}

      mine_past != [] and Enum.any?(now, & &1.dated?) ->
        %{status: :superseded, fact: List.last(mine_past), current: now}

      mine_past != [] ->
        %{status: :closed, fact: List.last(mine_past), current: now}

      true ->
        %{status: :unknown, fact: nil, current: now}
    end
  end

  # --- internals: write ------------------------------------------------------------------------

  defp assert_state(edge, key, nil, source, origin) do
    case open_row(edge.id, source) do
      nil ->
        Repo.query!(
          """
          INSERT INTO edge_validity (edge_id, supersession_key, source, origin, valid_from, observed_at)
          VALUES ($1, $2, $3, $4, NULL, NULL)
          """,
          [edge.id, key, source, origin]
        )

        {:ok, :undated}

      _open ->
        {:ok, :undated}
    end
  end

  defp assert_state(edge, key, %DateTime{} = t, source, origin) do
    own = open_row(edge.id, source)

    cond do
      # Re-attestation of the open interval (or a dated observation of an undated one): the
      # identity is unchanged, the fact's valid time advances.
      not is_nil(own) and (is_nil(own.valid_from) or DateTime.compare(own.valid_from, t) != :gt) ->
        Repo.query!(
          """
          UPDATE edge_validity
             SET observed_at = CASE WHEN observed_at IS NULL OR observed_at < $2 THEN $2 ELSE observed_at END,
                 origin = coalesce($3, origin),
                 updated_at = now()
           WHERE id = $1
          """,
          [own.id, t, origin]
        )

        close_superseded(edge.id, key, t)
        {:ok, :extended}

      # Something dated on this key already started after t: this observation is history.
      newer_open_exists?(key, t) ->
        record_historical(edge.id, key, t, source, origin)

      true ->
        Repo.query!(
          """
          INSERT INTO edge_validity (edge_id, supersession_key, source, origin, valid_from, observed_at)
          VALUES ($1, $2, $3, $4, $5, $5)
          """,
          [edge.id, key, source, origin, t]
        )

        close_superseded(edge.id, key, t)
        {:ok, :opened}
    end
  end

  # Close every OTHER edge's open interval on the key at t: undated ones unconditionally, dated
  # ones only when they started at or before t (a later start is the late-arriving case, handled
  # before we get here).
  defp close_superseded(edge_id, key, t) do
    Repo.query!(
      """
      UPDATE edge_validity
         SET valid_to = $3, closed_reason = 'superseded', closed_at = now(), updated_at = now()
       WHERE supersession_key = $1
         AND edge_id <> $2
         AND valid_to IS NULL
         AND (valid_from IS NULL OR valid_from <= $3)
      """,
      [key, edge_id, t]
    )

    :ok
  end

  defp newer_open_exists?(key, t) do
    %{rows: [[exists]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM edge_validity
           WHERE supersession_key = $1 AND valid_to IS NULL AND valid_from > $2
        )
        """,
        [key, t]
      )

    exists
  end

  # A late-arriving dated fact: closed history `[t, next_start)`, where next_start is the earliest
  # later interval start on the key (any edge, any source) or on this (edge, source) timeline —
  # whichever comes first — so the row can never overlap. A no-op if this source already covers t.
  defp record_historical(edge_id, key, t, source, origin) do
    %{rows: [[covered, next_start]]} =
      Repo.query!(
        """
        SELECT EXISTS (
                 SELECT 1 FROM edge_validity
                  WHERE edge_id = $1 AND source = $2
                    AND (valid_from IS NULL OR valid_from <= $3)
                    AND (valid_to IS NULL OR valid_to > $3)
               ),
               (SELECT min(valid_from) FROM edge_validity
                 WHERE (supersession_key = $4 OR (edge_id = $1 AND source = $2))
                   AND valid_from > $3)
        """,
        [edge_id, source, t, key]
      )

    cond do
      covered ->
        {:ok, :historical}

      is_nil(next_start) ->
        {:error, {:temporal_inconsistent, key}}

      true ->
        Repo.query!(
          """
          INSERT INTO edge_validity
            (edge_id, supersession_key, source, origin, valid_from, valid_to, observed_at,
             closed_reason, closed_at)
          VALUES ($1, $2, $3, $4, $5, $6, $5, 'superseded', now())
          """,
          [edge_id, key, source, origin, t, next_start]
        )

        {:ok, :historical}
    end
  end

  defp open_row(edge_id, source) do
    case Repo.query!(
           "SELECT id, valid_from, observed_at FROM edge_validity WHERE edge_id = $1 AND source = $2 AND valid_to IS NULL",
           [edge_id, source]
         ).rows do
      [[id, valid_from, observed_at]] ->
        %{id: id, valid_from: valid_from, observed_at: observed_at}

      [] ->
        nil
    end
  end

  defp edge_row(edge_id) do
    case Repo.query!(
           "SELECT id, src, dst, type, visibility_scope FROM edge WHERE id = $1",
           [edge_id]
         ).rows do
      [[id, src, dst, type, scope]] -> %{id: id, src: src, dst: dst, type: type, scope: scope}
      [] -> nil
    end
  end

  @doc "The supersession key text for an edge under a registry-declared supersession rule."
  @spec supersession_key(map(), :subject_relation | :subject_relation_object) :: String.t()
  def supersession_key(%{src: src, type: type, scope: scope}, :subject_relation),
    do: "#{src}|#{type}|#{scope}"

  def supersession_key(%{src: src, dst: dst, type: type, scope: scope}, :subject_relation_object),
    do: "#{src}|#{type}|#{dst}|#{scope}"

  defp lock!(key) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  # --- internals: read -------------------------------------------------------------------------

  defp facts_sql(extra_where, order) do
    """
    SELECT e.id, s.key, e.type, d.key, e.visibility_scope,
           v.id, v.valid_from, v.valid_to, v.observed_at, v.source, v.closed_reason, v.absent_at
      FROM edge e
      JOIN node s ON s.id = e.src
      JOIN node d ON d.id = e.dst
      LEFT JOIN edge_validity v ON v.edge_id = e.id
     WHERE s.key = $1 AND e.type = $2 AND e.reward >= 0
    #{extra_where}
    #{order}
    """
  end

  defp scope_clause(nil, _n), do: {"", []}

  defp scope_clause(scopes, n) when is_list(scopes) do
    {"AND e.visibility_scope = ANY($#{n}) AND s.scope = ANY($#{n}) AND d.scope = ANY($#{n})",
     [scopes]}
  end

  defp row_to_fact([
         edge_id,
         subject,
         relation,
         object,
         scope,
         interval_id,
         valid_from,
         valid_to,
         observed_at,
         source,
         closed_reason,
         absent_at
       ]) do
    %{
      edge_id: edge_id,
      subject: subject,
      relation: relation,
      object: object,
      scope: scope,
      interval_id: interval_id,
      valid_from: valid_from,
      valid_to: valid_to,
      observed_at: observed_at,
      dated?: not is_nil(observed_at),
      source: source,
      closed_reason: closed_reason,
      absent_at: absent_at
    }
  end
end
