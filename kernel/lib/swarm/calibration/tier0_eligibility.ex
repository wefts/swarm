defmodule Swarm.Calibration.Tier0Eligibility do
  @moduledoc """
  Earned eligibility for judge-free structured serving.

  This is a predicate only. It does not grade answers and it does not mint
  reward; it reads graph state and recorded contradiction flags.
  """

  alias Swarm.Graph.Network
  alias Swarm.Repo
  alias Swarm.WorldMap.Coverage.Validated

  @min_agreement 0.8

  @spec eligible?(Validated.t(), keyword()) :: boolean()
  def eligible?(%Validated{intent: :neighborhood, domain: :network, key: key, atoms: facts}, opts)
      when is_binary(key) and facts != [] do
    scopes = Keyword.get(opts, :scopes, [])

    unique_subject?(key, scopes) and
      Enum.all?(facts, &eligible_fact?(key, &1)) and
      not contradicted?(key, facts) and
      Enum.all?(facts, &high_agreement?(key, &1.relation, scopes))
  end

  def eligible?(_, _opts), do: false

  defp unique_subject?(key, scopes) do
    case Repo.query!(
           "SELECT count(*) FROM node WHERE key = $1 AND scope = ANY($2)",
           [key, scopes]
         ) do
      %{rows: [[1]]} -> true
      _ -> false
    end
  end

  defp eligible_fact?(_key, %{relation: relation, corroboration: corr})
       when is_integer(corr) do
    Network.cardinality(relation) in [:single, :many] and corr >= 2
  end

  defp eligible_fact?(_, _), do: false

  defp contradicted?(key, facts) do
    relations = Enum.map(facts, & &1.relation)

    case Repo.query!(
           """
           SELECT 1
             FROM calibration_contradiction
            WHERE subject_key = $1
              AND relation = ANY($2)
              AND verdict = 'contradicted'
            LIMIT 1
           """,
           [key, relations]
         ) do
      %{rows: []} -> false
      _ -> true
    end
  rescue
    Postgrex.Error -> false
  end

  defp high_agreement?(key, relation, scopes) do
    case Repo.query!(
           """
           SELECT bool_or(agreement >= $2)
             FROM answer_record
            WHERE agreement IS NOT NULL
              AND scopes <@ $4::text[]
              AND query ~* $3
              AND EXISTS (
                SELECT 1
                  FROM jsonb_array_elements(citations) AS c
                 WHERE c->>'ref' = $1
              )
           """,
           [key, @min_agreement, relation_pattern(relation), scopes]
         ) do
      %{rows: [[true]]} -> true
      _ -> false
    end
  rescue
    Postgrex.Error -> false
  end

  defp relation_pattern("has_private_address"), do: "\\m(private|internal|lan)\\M"
  defp relation_pattern("has_public_address"), do: "\\m(public|external|outbound|egress)\\M"
  defp relation_pattern("has_outbound_ip_address"), do: "\\m(outbound|egress|public|external)\\M"
  defp relation_pattern(relation), do: Regex.escape(relation)
end
