defmodule Swarm.Deliberation do
  @moduledoc """
  Retained panel-vs-judge deliberations (swarm ADR-15) — the read-only "how it
  decided" surface for the dashboard.

  The `Consilium.deliberate/2` verdict is discarded once the answer is built. This
  persists it keyed by an **opaque, high-entropy `ask_ref`**, stamped with the
  asking `viewer` + the scopes the retrieval ran under, so a past escalated answer
  can re-open its panel view. Retention is bounded by config (`Config.deliberation`):
  a TTL + a max-row cap, reaped on the existing ADR-10 trace-GC pass (no new timer).

  No-leak (the kernel is the scope authority): a row is returned **only** when the
  requesting `viewer` owns it **and** the request's current scopes still *cover* the
  stored scopes (a viewer who lost a scope must not re-open a deliberation derived
  under it). Any failure ⇒ `:not_found` — existence is never revealed. **Anonymous
  escalations are not retained** (no owner to re-open to).
  """

  alias Swarm.{Config, Repo}

  @type take :: %{model: String.t(), answer: String.t()}
  @type record :: %{
          ask_ref: String.t(),
          answer: String.t(),
          confidence: float(),
          disagreement: float(),
          panel: [take()],
          judge: String.t(),
          created_at: String.t()
        }

  @doc "Whether retention is enabled (the kill-switch; `Config.deliberation.enabled`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.deliberation().enabled

  @doc """
  Persist a verdict and return its opaque `ask_ref`, or `""` when not retained
  (retention disabled, or an anonymous asker — empty `viewer`). A single insert,
  called **after** `deliberate/2` has returned (never holds a connection across the
  LLM). `verdict` is the `Swarm.Consilium.verdict()` map.
  """
  @spec maybe_persist(map(), String.t(), [String.t()]) :: String.t()
  def maybe_persist(_verdict, "", _scopes), do: ""

  def maybe_persist(verdict, viewer, scopes) when is_binary(viewer) do
    if enabled?() do
      ask_ref = mint_ref()
      panel = Enum.map(verdict.panel, fn t -> %{"model" => t.model, "answer" => t.answer} end)

      Repo.query!(
        """
        INSERT INTO deliberation
          (ask_ref, viewer, scopes, answer, confidence, disagreement, panel, judge)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        """,
        [
          ask_ref,
          viewer,
          scopes,
          verdict.answer,
          verdict.confidence,
          verdict.disagreement,
          Jason.encode!(panel),
          verdict.judge
        ]
      )

      ask_ref
    else
      ""
    end
  end

  @doc """
  Fetch a retained deliberation for `ask_ref`, returned **only** to the owning
  `viewer` whose current `scopes` still cover the stored scopes. Every other
  outcome — empty/unknown `ask_ref`, viewer mismatch, scopes no longer cover —
  is `:not_found` (existence never revealed; no partial read).
  """
  @spec fetch(String.t(), String.t(), [String.t()]) :: {:ok, record()} | :not_found
  def fetch("", _viewer, _scopes), do: :not_found
  def fetch(_ask_ref, "", _scopes), do: :not_found

  def fetch(ask_ref, viewer, scopes) when is_binary(ask_ref) and is_binary(viewer) do
    # Owner-match is in the WHERE (defense-in-depth: a non-owner never reads the
    # row); the scope-cover re-auth is applied below. Both failures and an unknown
    # ask_ref collapse to the same `:not_found` — existence is never revealed.
    case Repo.query!(
           """
           SELECT scopes, answer, confidence, disagreement, panel, judge, created_at
             FROM deliberation WHERE ask_ref = $1 AND viewer = $2
           """,
           [ask_ref, viewer]
         ) do
      %{rows: [[stored_scopes, answer, confidence, disagreement, panel, judge, created_at]]} ->
        if covers?(scopes, stored_scopes) do
          {:ok,
           %{
             ask_ref: ask_ref,
             answer: answer,
             confidence: confidence,
             disagreement: disagreement,
             panel: decode_panel(panel),
             judge: judge,
             created_at: format_ts(created_at)
           }}
        else
          :not_found
        end

      %{rows: []} ->
        :not_found
    end
  end

  @doc """
  Reap retained deliberations past the TTL **or** beyond the row cap (oldest-first),
  the pure operation called on the ADR-10 trace-GC pass (and directly in tests).
  Returns the count reaped. `opts`: `:ttl_days`, `:max_rows` (default from config).
  """
  @spec reap(keyword()) :: non_neg_integer()
  def reap(opts \\ []) do
    cfg = Config.deliberation()
    # Guard against a fat-fingered config: a non-positive cap with an OFFSET-based
    # eviction would wipe the whole store (council). Floor ttl at 0, cap at 1.
    ttl_days = max(Keyword.get(opts, :ttl_days, cfg.retention_ttl_days), 0)
    max_rows = max(Keyword.get(opts, :max_rows, cfg.max_rows), 1)

    %{num_rows: by_ttl} =
      Repo.query!(
        "DELETE FROM deliberation WHERE created_at < now() - ($1::int * interval '1 day')",
        [ttl_days]
      )

    %{num_rows: by_cap} =
      Repo.query!(
        """
        DELETE FROM deliberation WHERE ask_ref IN (
          SELECT ask_ref FROM deliberation ORDER BY created_at DESC, ask_ref OFFSET $1
        )
        """,
        [max_rows]
      )

    by_ttl + by_cap
  end

  # An opaque, high-entropy id — NOT a guessable/enumerable sequence (ADR-15).
  @spec mint_ref() :: String.t()
  defp mint_ref, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # Current request scopes must be a superset of the scopes the retrieval ran under.
  @spec covers?([String.t()], [String.t()]) :: boolean()
  defp covers?(current, stored), do: Enum.all?(stored, &(&1 in current))

  @spec decode_panel(String.t()) :: [take()]
  defp decode_panel(json) do
    json
    |> Jason.decode!()
    |> Enum.map(fn t -> %{model: Map.get(t, "model", ""), answer: Map.get(t, "answer", "")} end)
  end

  @spec format_ts(term()) :: String.t()
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_ts(other), do: to_string(other)
end
