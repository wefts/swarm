defmodule Swarm.Calibration.Contradictions do
  @moduledoc """
  Deterministic disagreement detection between past answers and structured facts.

  This is deliberately narrow at first: network private-address answers are
  compared with graph `has_private_address` facts using parsed IP/CIDR semantics.
  No answer grades itself; this only compares independent derivations.
  """

  alias Swarm.Graph.Network
  alias Swarm.Repo

  @type verdict :: :corroborated | :contradicted | :not_comparable
  @type result :: %{
          ask_ref: String.t(),
          verdict: verdict(),
          relation: String.t() | nil,
          subject: String.t() | nil,
          explanation: String.t()
        }

  @ip_or_cidr ~r/\b(?:\d{1,3}\.){3}\d{1,3}(?:\/\d{1,2})?\b/

  @spec run(keyword()) :: %{
          corroborated: non_neg_integer(),
          contradicted: non_neg_integer(),
          not_comparable: non_neg_integer(),
          results: [result()]
        }
  def run(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    results =
      Repo.query!(
        """
        SELECT ask_ref, query, answer, scopes, citations
          FROM answer_record
         WHERE tier = 'escalate'
         ORDER BY created_at DESC
         LIMIT $1
        """,
        [limit]
      ).rows
      |> Enum.map(fn [ask_ref, query, answer, scopes, citations] ->
        classify(%{
          ask_ref: ask_ref,
          query: query,
          answer: answer,
          scopes: scopes,
          citations: citations
        })
      end)

    Enum.each(results, &persist/1)

    %{
      corroborated: Enum.count(results, &(&1.verdict == :corroborated)),
      contradicted: Enum.count(results, &(&1.verdict == :contradicted)),
      not_comparable: Enum.count(results, &(&1.verdict == :not_comparable)),
      results: results
    }
  end

  @spec persist(result()) :: :ok
  def persist(%{
        ask_ref: ask_ref,
        verdict: verdict,
        relation: relation,
        subject: subject,
        explanation: explanation
      }) do
    Repo.query!(
      """
      INSERT INTO calibration_contradiction
        (ask_ref, subject_key, relation, verdict, explanation)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (ask_ref) DO UPDATE SET
        subject_key = EXCLUDED.subject_key,
        relation = EXCLUDED.relation,
        verdict = EXCLUDED.verdict,
        explanation = EXCLUDED.explanation
      """,
      [ask_ref, subject, relation, Atom.to_string(verdict), explanation]
    )

    :ok
  end

  @spec classify(map()) :: result()
  def classify(%{ask_ref: ask_ref, query: query, answer: answer, scopes: scopes} = record) do
    with :private_address <- relation(query),
         {:ok, candidate} <- subject_candidate(query, scopes, Map.get(record, :citations)),
         graph_values when graph_values != [] <-
           graph_private_addresses(candidate, scopes, ask_ref),
         answer_values when answer_values != [] <- address_literals(answer) do
      compare_values(ask_ref, candidate, answer_values, graph_values)
    else
      _ ->
        %{
          ask_ref: ask_ref,
          verdict: :not_comparable,
          relation: nil,
          subject: nil,
          explanation: "no supported deterministic comparator for this answer"
        }
    end
  end

  defp relation(query) do
    q = String.downcase(query || "")

    if String.contains?(q, "private") and Regex.match?(~r/\b(ip|address)\b/, q),
      do: :private_address,
      else: :unknown
  end

  defp subject_candidate(query, scopes, citations) do
    case cited_network_subject(citations) do
      subject when is_binary(subject) ->
        {:ok, subject}

      nil ->
        case Network.candidates(query, scopes) do
          [candidate | _] -> {:ok, candidate}
          [] -> :error
        end
    end
  end

  defp cited_network_subject(citations) when is_binary(citations) do
    case Jason.decode!(citations) do
      nested when is_binary(nested) -> cited_network_subject(Jason.decode!(nested))
      decoded -> cited_network_subject(decoded)
    end
  rescue
    _ -> nil
  end

  defp cited_network_subject(citations) when is_list(citations) do
    citations
    |> Enum.map(fn c -> c["ref"] || c[:ref] end)
    |> Enum.find(&(is_binary(&1) and String.starts_with?(&1, "net:")))
  end

  defp cited_network_subject(_), do: nil

  defp graph_private_addresses(candidate, scopes, ask_ref) do
    self_origin = "answer:#{ask_ref}"

    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT d.key
          FROM edge e
          JOIN node s ON s.id = e.src
          JOIN node d ON d.id = e.dst
         WHERE s.key = $1
           AND e.type = 'has_private_address'
           AND e.reward >= 0
           AND e.visibility_scope = ANY($2)
           AND s.scope = ANY($2)
           AND d.scope = ANY($2)
           AND EXISTS (
             SELECT 1
               FROM edge_provenance ep
              WHERE ep.edge_id = e.id
                AND coalesce(ep.origin, ep.provenance) <> $3
                AND coalesce(ep.origin, ep.provenance) NOT LIKE 'answer:%'
           )
        """,
        [candidate, scopes, self_origin]
      )

    Enum.map(rows, fn [key] -> String.replace_prefix(key, "net:address:", "") end)
  end

  defp address_literals(text) do
    @ip_or_cidr
    |> Regex.scan(text || "")
    |> List.flatten()
  end

  defp compare_values(ask_ref, subject, answer_values, graph_values) do
    cond do
      Enum.any?(answer_values, &exact_or_contains?(&1, graph_values)) ->
        %{
          ask_ref: ask_ref,
          verdict: :corroborated,
          relation: "has_private_address",
          subject: subject,
          explanation:
            "answer value matches the graph fact or contains it at broader CIDR granularity"
        }

      Enum.any?(answer_values, &parse_address_or_net/1) ->
        %{
          ask_ref: ask_ref,
          verdict: :contradicted,
          relation: "has_private_address",
          subject: subject,
          explanation:
            "answer contains address data, but none matches or contains the graph private address"
        }

      true ->
        %{
          ask_ref: ask_ref,
          verdict: :not_comparable,
          relation: "has_private_address",
          subject: subject,
          explanation: "answer has no parseable address value"
        }
    end
  end

  defp exact_or_contains?(answer_value, graph_values) do
    Enum.any?(graph_values, fn graph_value ->
      answer_value == graph_value or contains?(answer_value, graph_value)
    end)
  end

  defp contains?(cidr, address) do
    if String.contains?(cidr, "/") and parse_address(address) == :ok do
      case Repo.query!(
             "SELECT swarm_try_inet($1) <<= swarm_try_cidr($2)",
             [address, cidr]
           ) do
        %{rows: [[true]]} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp parse_address_or_net(value) do
    cond do
      String.contains?(value, "/") ->
        case Repo.query!("SELECT swarm_try_cidr($1) IS NOT NULL", [value]) do
          %{rows: [[true]]} -> :ok
          _ -> :error
        end

      parse_address(value) == :ok ->
        :ok

      true ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_address(value) do
    case value |> String.to_charlist() |> :inet.parse_address() do
      {:ok, _} -> :ok
      _ -> :error
    end
  end
end
