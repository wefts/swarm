defmodule Swarm.Calibration.Reward do
  @moduledoc """
  Reward application for the calibration loop.

  ADR-11 invariant: accepted inputs are external ratings, independent
  derivation comparisons, or source precedence. A system answer alone is never a
  reward signal.
  """

  alias Swarm.Repo

  @spec apply_signal(tuple()) :: non_neg_integer()
  def apply_signal({:self_answer, _ask_ref}), do: 0

  def apply_signal({:rating, ask_ref}) do
    with {:ok, rating, query, refs, scopes} <- rating_refs(ask_ref),
         delta when delta != 0.0 <- rating_delta(rating) do
      case relation_target(query, refs) do
        {:ok, subject, relation} ->
          update_edges_for_subject_relation(subject, relation, delta, scopes: scopes)

        :fallback ->
          update_edges_for_refs(refs, scopes, delta)
      end
    else
      _ -> 0
    end
  end

  def apply_signal({:derivation, %{verdict: :corroborated, subject: subject, relation: relation}})
      when is_binary(subject) and is_binary(relation) do
    update_edges_for_subject_relation(subject, relation, 0.15, independent_only?: true)
  end

  def apply_signal({:derivation, %{verdict: :contradicted, subject: subject, relation: relation}})
      when is_binary(subject) and is_binary(relation) do
    update_edges_for_subject_relation(subject, relation, -1.0, independent_only?: true)
  end

  def apply_signal({:authoritative_source, origin}) when is_binary(origin) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE edge e
           SET reward = GREATEST(reward, 0.2)
         WHERE EXISTS (
           SELECT 1 FROM edge_provenance ep
            WHERE ep.edge_id = e.id
              AND coalesce(ep.lineage, ep.origin, ep.provenance) = $1
         )
        """,
        [origin]
      )

    n
  end

  def apply_signal(_), do: 0

  defp rating_refs(ask_ref) do
    case Repo.query!(
           """
           SELECT r.rating, ar.query, ar.citations, ar.scopes
             FROM answer_rating r
             JOIN answer_record ar ON ar.ask_ref = r.ask_ref AND ar.viewer = r.viewer
            WHERE r.ask_ref = $1
            ORDER BY r.updated_at DESC
            LIMIT 1
           """,
           [ask_ref]
         ) do
      %{rows: [[rating, query, citations, scopes]]} ->
        {:ok, rating, query, citation_refs(citations), scopes}

      %{rows: []} ->
        :not_found
    end
  end

  defp citation_refs(citations) when is_binary(citations) do
    case Jason.decode!(citations) do
      nested when is_binary(nested) -> nested |> Jason.decode!() |> citation_refs()
      decoded -> citation_refs(decoded)
    end
  end

  defp citation_refs(citations) when is_list(citations) do
    citations
    |> Enum.map(fn c -> c["ref"] || c[:ref] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&String.starts_with?(&1, "corroboration:"))
  end

  defp citation_refs(_), do: []

  defp rating_delta("helpful"), do: 0.1
  defp rating_delta("wrong"), do: -1.0
  defp rating_delta("unsure"), do: 0.0

  defp relation_target(query, refs) do
    with subject when is_binary(subject) <- Enum.find(refs, &String.starts_with?(&1, "net:")),
         relation when is_binary(relation) <- network_relation(query) do
      {:ok, subject, relation}
    else
      _ -> :fallback
    end
  end

  defp network_relation(query) do
    q = String.downcase(query || "")

    cond do
      Regex.match?(~r/\b(private|internal|lan)\b/, q) and Regex.match?(~r/\b(ip|address)\b/, q) ->
        "has_private_address"

      Regex.match?(~r/\b(public|external)\b/, q) and Regex.match?(~r/\b(ip|address)\b/, q) ->
        "has_public_address"

      Regex.match?(~r/\b(outbound|egress)\b/, q) and Regex.match?(~r/\b(ip|address)\b/, q) ->
        "has_outbound_ip_address"

      Regex.match?(~r/\b(ip|address)\b/, q) ->
        "has_address"

      true ->
        nil
    end
  end

  defp update_edges_for_refs([], _scopes, _delta), do: 0

  defp update_edges_for_refs(refs, scopes, delta) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE edge e
           SET reward = reward + $3
          FROM node s, node d
         WHERE e.src = s.id
           AND e.dst = d.id
           AND e.visibility_scope = ANY($2)
           AND (s.key = ANY($1) OR d.key = ANY($1))
        """,
        [refs, scopes, delta]
      )

    n
  end

  defp update_edges_for_subject_relation(subject, relation, delta, opts) do
    scopes = Keyword.get(opts, :scopes)

    independent_sql =
      if Keyword.get(opts, :independent_only?, false) do
        """
           AND EXISTS (
             SELECT 1 FROM edge_provenance ep
              WHERE ep.edge_id = e.id
                AND e.evidence_kind NOT IN ('claim', 'hypothesis', 'derived')
           )
        """
      else
        ""
      end

    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE edge e
           SET reward = reward + $3
          FROM node s
         WHERE e.src = s.id
           AND s.key = $1
           AND e.type = $2
           AND ($4::text[] IS NULL OR e.visibility_scope = ANY($4))
        #{independent_sql}
        """,
        [subject, relation, delta, scopes]
      )

    n
  end
end
