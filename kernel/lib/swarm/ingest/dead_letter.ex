defmodule Swarm.Ingest.DeadLetter do
  @moduledoc """
  Poison-trace dead-letter zone (T10). An ingest event the pipeline cannot process
  — malformed shape, a bad timestamp, a graph-contract violation (ADR-4) — is
  **quarantined here with its reason** instead of being silently dropped or
  raised into the pipeline (which would let one poison trace stall a stage).

  Durable (a Postgres table), inspectable (`count/0`, `recent/1`), and a terminal
  sink — a quarantined event never re-enters ingest on its own.
  """

  alias Swarm.Repo

  require Logger

  @doc """
  Quarantine an un-processable event with its reason. The payload is encoded
  best-effort (an unencodable one is recorded as such, never crashing here). The
  INSERT itself can still raise if Postgres is down — but that is a transport
  outage, not a poison trace, and is allowed to propagate (fail-loud).
  """
  @spec quarantine(map(), term()) :: :ok
  def quarantine(event, reason) do
    payload = safe_encode(event)
    reason_text = inspect(reason)

    Repo.query!(
      "INSERT INTO dead_letter (payload, reason) VALUES ($1::jsonb, $2)",
      [payload, reason_text]
    )

    Logger.warning("ingest: quarantined a poison trace — #{reason_text}")
    :ok
  end

  @doc "How many poison traces are quarantined."
  @spec count() :: non_neg_integer()
  def count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM dead_letter")
    n
  end

  @doc "The most recent `n` quarantined traces (reason + payload), newest first."
  @spec recent(pos_integer()) :: [%{reason: String.t(), payload: map()}]
  def recent(n \\ 20) when is_integer(n) and n > 0 do
    %{rows: rows} =
      Repo.query!(
        "SELECT reason, payload FROM dead_letter ORDER BY id DESC LIMIT $1",
        [n]
      )

    Enum.map(rows, fn [reason, payload] -> %{reason: reason, payload: payload} end)
  end

  # Encode best-effort; a payload that won't encode is itself recorded as a reason
  # rather than crashing the quarantine path (encoding never fails the sink; a
  # Postgres outage on the INSERT still propagates as transport, per the moduledoc).
  defp safe_encode(event) do
    Jason.encode!(event)
  rescue
    _ -> Jason.encode!(%{unencodable: inspect(event)})
  end
end
