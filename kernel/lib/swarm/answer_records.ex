defmodule Swarm.AnswerRecords do
  @moduledoc """
  Kernel-owned answer records and external ratings.

  ADR-11 boundary: this module records external feedback and measured metadata.
  It never asks the answerer to grade itself and never changes graph reward.
  """

  alias Swarm.Repo

  @type rating :: :helpful | :wrong | :unsure
  @type record :: %{
          ask_ref: String.t(),
          viewer: String.t(),
          scopes: [String.t()],
          query: String.t(),
          answer: String.t(),
          tier: String.t(),
          status: String.t(),
          confidence: float(),
          agreement: float() | nil,
          citations: [map()],
          created_at: String.t()
        }

  @spec maybe_persist(String.t(), [String.t()], String.t(), map()) :: String.t()
  def maybe_persist("", _scopes, _query, answer), do: Map.get(answer, :ask_ref, "")

  def maybe_persist(viewer, scopes, query, answer) when is_binary(viewer) and is_list(scopes) do
    ask_ref = Map.get(answer, :ask_ref, "") |> present_or(fn -> mint_ref() end)
    agreement = Map.get(answer, :agreement)

    Repo.query!(
      """
      INSERT INTO answer_record
        (ask_ref, viewer, scopes, query, answer, tier, status, confidence, agreement, citations)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, ($10::jsonb #>> '{}')::jsonb)
      ON CONFLICT (ask_ref) DO UPDATE SET
        viewer = EXCLUDED.viewer,
        scopes = EXCLUDED.scopes,
        query = EXCLUDED.query,
        answer = EXCLUDED.answer,
        tier = EXCLUDED.tier,
        status = EXCLUDED.status,
        confidence = EXCLUDED.confidence,
        agreement = EXCLUDED.agreement,
        citations = EXCLUDED.citations
      """,
      [
        ask_ref,
        viewer,
        scopes,
        query,
        Map.fetch!(answer, :answer),
        Map.fetch!(answer, :tier),
        Atom.to_string(Map.fetch!(answer, :status)),
        Map.fetch!(answer, :confidence),
        agreement,
        Jason.encode!(Map.get(answer, :citations, []))
      ]
    )

    ask_ref
  end

  @spec rate(String.t(), String.t(), [String.t()], rating() | String.t() | atom()) ::
          {:ok, rating()} | :not_found | :bad_request
  def rate(ask_ref, viewer, scopes, rating)
      when is_binary(ask_ref) and is_binary(viewer) and is_list(scopes) do
    with {:ok, normalized} <- normalize_rating(rating),
         true <- ask_ref != "" and viewer != "" do
      case fetch_owner_scope(ask_ref, viewer) do
        {:ok, stored_scopes} ->
          if covers?(scopes, stored_scopes) do
            upsert_rating(ask_ref, viewer, normalized)
            {:ok, normalized}
          else
            :not_found
          end

        :not_found ->
          :not_found
      end
    else
      _ -> :bad_request
    end
  end

  def rate(_ask_ref, _viewer, _scopes, _rating), do: :bad_request

  @spec fetch(String.t(), String.t(), [String.t()]) :: {:ok, record()} | :not_found
  def fetch(ask_ref, viewer, scopes) when is_binary(ask_ref) and is_binary(viewer) do
    case Repo.query!(
           """
           SELECT scopes, query, answer, tier, status, confidence, agreement, citations, created_at
             FROM answer_record
            WHERE ask_ref = $1 AND viewer = $2
           """,
           [ask_ref, viewer]
         ) do
      %{
        rows: [
          [
            stored_scopes,
            query,
            answer,
            tier,
            status,
            confidence,
            agreement,
            citations,
            created_at
          ]
        ]
      } ->
        if covers?(scopes, stored_scopes) do
          {:ok,
           %{
             ask_ref: ask_ref,
             viewer: viewer,
             scopes: stored_scopes,
             query: query,
             answer: answer,
             tier: tier,
             status: status,
             confidence: confidence,
             agreement: agreement,
             citations: decode_json(citations),
             created_at: format_ts(created_at)
           }}
        else
          :not_found
        end

      %{rows: []} ->
        :not_found
    end
  end

  @spec fetch_rating(String.t(), String.t()) :: {:ok, rating()} | :not_found
  def fetch_rating(ask_ref, viewer) do
    case Repo.query!(
           "SELECT rating FROM answer_rating WHERE ask_ref = $1 AND viewer = $2",
           [ask_ref, viewer]
         ) do
      %{rows: [[rating]]} -> normalize_rating(rating)
      %{rows: []} -> :not_found
    end
  end

  @spec backfill_agreement_from_deliberation() :: non_neg_integer()
  def backfill_agreement_from_deliberation do
    %{num_rows: n} =
      Repo.query!("""
      UPDATE answer_record ar
         SET agreement = 1.0 - d.disagreement
        FROM deliberation d
       WHERE ar.ask_ref = d.ask_ref
         AND ar.agreement IS NULL
      """)

    n
  end

  @spec mint_ref() :: String.t()
  def mint_ref, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp fetch_owner_scope(ask_ref, viewer) do
    case Repo.query!("SELECT scopes FROM answer_record WHERE ask_ref = $1 AND viewer = $2", [
           ask_ref,
           viewer
         ]) do
      %{rows: [[scopes]]} -> {:ok, scopes}
      %{rows: []} -> :not_found
    end
  end

  defp upsert_rating(ask_ref, viewer, rating) do
    Repo.query!(
      """
      INSERT INTO answer_rating (ask_ref, viewer, rating)
      VALUES ($1, $2, $3)
      ON CONFLICT (ask_ref, viewer) DO UPDATE SET
        rating = EXCLUDED.rating,
        updated_at = now()
      """,
      [ask_ref, viewer, Atom.to_string(rating)]
    )
  end

  defp normalize_rating(rating) when is_atom(rating), do: normalize_rating(Atom.to_string(rating))

  defp normalize_rating(rating) when is_binary(rating) do
    case String.downcase(rating) do
      "helpful" -> {:ok, :helpful}
      "wrong" -> {:ok, :wrong}
      "unsure" -> {:ok, :unsure}
      _ -> :error
    end
  end

  defp normalize_rating(_), do: :error

  defp covers?(current, stored), do: Enum.all?(stored, &(&1 in current))

  defp decode_json(value) when is_binary(value) do
    case Jason.decode!(value) do
      nested when is_binary(nested) -> Jason.decode!(nested)
      decoded -> decoded
    end
  end

  defp decode_json(value), do: value || []

  defp present_or("", fun), do: fun.()
  defp present_or(nil, fun), do: fun.()
  defp present_or(value, _fun), do: value

  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_ts(other), do: to_string(other)
end
