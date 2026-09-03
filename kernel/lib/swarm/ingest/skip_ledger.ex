defmodule Swarm.Ingest.SkipLedger do
  @moduledoc """
  Durable ledger for connector-side source items intentionally skipped before
  ingest.

  Rows are privacy-safe by contract: connector/source identity, stable source_ref,
  machine reason, and source occurrence time. Do not put page titles, body text, or
  URLs here.
  """

  alias Swarm.Repo

  require Logger

  @connector_re ~r/^[A-Za-z0-9_.]+$/
  @source_re ~r/^[a-z][a-z0-9_-]*$/
  # `<source>:<segment>` with one or more colon-separated segments, so a site-qualified
  # reference (`proxmox:casa:vm:101`) is as valid as a flat one (`confluence:101`).
  @source_ref_re ~r/^[a-z][a-z0-9_-]*(:[A-Za-z0-9_.-]+)+$/
  @reason_re ~r/^[a-z][a-z0-9_]*$/

  @doc "Record one connector-side skip. Replays update the existing reason row."
  @spec record(map()) :: :ok | {:error, term()}
  def record(skip) when is_map(skip) do
    with {:ok, connector} <- fetch_string(skip, :connector, @connector_re),
         {:ok, source} <- fetch_string(skip, :source, @source_re),
         {:ok, source_ref} <- fetch_string(skip, :source_ref, @source_ref_re),
         {:ok, reason} <- fetch_string(skip, :reason, @reason_re),
         {:ok, occurred_at} <- to_utc(Map.get(skip, :occurred_at)) do
      Repo.query!(
        """
        INSERT INTO ingest_skip (connector, source, source_ref, reason, occurred_at)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (connector, source_ref, reason)
        DO UPDATE SET source = EXCLUDED.source,
                      occurred_at = EXCLUDED.occurred_at,
                      inserted_at = now()
        """,
        [connector, source, source_ref, reason, occurred_at]
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("ingest skip ledger: rejected skip row (#{inspect(reason)})")
        {:error, reason}
    end
  end

  @doc "How many connector-side skips are recorded."
  @spec count() :: non_neg_integer()
  def count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM ingest_skip")
    n
  end

  @doc "Privacy-safe aggregate by connector/source/reason."
  @spec summary() :: [
          %{connector: String.t(), source: String.t(), reason: String.t(), count: integer()}
        ]
  def summary do
    %{rows: rows} =
      Repo.query!("""
      SELECT connector, source, reason, count(*)::int
      FROM ingest_skip
      GROUP BY connector, source, reason
      ORDER BY connector, source, reason
      """)

    Enum.map(rows, fn [connector, source, reason, count] ->
      %{connector: connector, source: source, reason: reason, count: count}
    end)
  end

  defp fetch_string(map, key, regex) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> validate_shape(key, v, regex)
      v when is_atom(v) -> validate_shape(key, Atom.to_string(v), regex)
      _ -> {:error, {:missing, key}}
    end
  end

  defp validate_shape(key, value, regex) do
    if Regex.match?(regex, value), do: {:ok, value}, else: {:error, {:malformed, key}}
  end

  defp to_utc(%DateTime{time_zone: "Etc/UTC"} = dt), do: {:ok, dt}
  defp to_utc(%DateTime{} = dt), do: {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

  defp to_utc(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:bad_timestamp, reason}}
    end
  end

  defp to_utc(nil), do: {:ok, DateTime.utc_now()}
  defp to_utc(other), do: {:error, {:bad_timestamp, other}}
end
