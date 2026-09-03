defmodule Swarm.Calibration.Reflection do
  @moduledoc """
  Idle conversion of past expensive answers into claim facts.

  This module does not decide whether an answer was correct. It converts only
  deterministic, parseable facts and preserves provenance back to the synthesis
  that produced them so later independent checks can corroborate or refute them.
  """

  alias Swarm.Graph.{NetworkAddress, Store}
  alias Swarm.Repo

  @ip ~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/

  @spec run(keyword()) :: %{written: non_neg_integer(), skipped: non_neg_integer()}
  def run(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    Repo.query!(
      """
      SELECT ask_ref, query, answer, scopes
        FROM answer_record
       WHERE tier = 'escalate'
       ORDER BY created_at DESC
       LIMIT $1
      """,
      [limit]
    ).rows
    |> Enum.reduce(%{written: 0, skipped: 0}, fn [ask_ref, query, answer, scopes], acc ->
      case convert_network_private_address(ask_ref, query, answer, scopes) do
        {:ok, n} -> %{acc | written: acc.written + n}
        :skip -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  @spec convert_network_private_address(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | :skip
  def convert_network_private_address(ask_ref, query, answer, [scope | _])
      when is_binary(ask_ref) and is_binary(query) and is_binary(answer) do
    with true <- private_address_query?(query),
         {:ok, subject} <- subject_key(query),
         {:ok, address} <- address_literal(answer) do
      source = Store.upsert_node("concept", "answer:#{ask_ref}", scope: scope)
      Repo.query!("UPDATE node SET kind = 'claim' WHERE id = $1", [source])
      subj = Store.upsert_node("entity", subject, scope: scope)
      dst = Store.upsert_node("entity", "net:address:#{address}", scope: scope)
      NetworkAddress.annotate_node(dst, "address", address)

      {:ok, %{id: _edge_id}} =
        Store.add_edge(subj, dst, "has_private_address", "reflection:#{ask_ref}:private-address",
          scope: scope,
          origin: "answer:#{ask_ref}",
          source_node_id: source,
          reliability: 0.45,
          evidence_kind: "claim"
        )

      {:ok, 1}
    else
      _ -> :skip
    end
  end

  def convert_network_private_address(_ask_ref, _query, _answer, _scopes), do: :skip

  defp private_address_query?(query) do
    q = String.downcase(query)
    String.contains?(q, "private") and Regex.match?(~r/\b(ip|address)\b/, q)
  end

  defp subject_key(query) do
    case Regex.run(~r/\b(?:of|for)\s+([a-z0-9][a-z0-9-]*)/i, query) ||
           Regex.run(~r/\bis\s+([a-z0-9][a-z0-9-]*)/i, query) do
      [_, name] -> {:ok, "net:host:#{String.downcase(name)}"}
      _ -> :error
    end
  end

  defp address_literal(answer) do
    case Regex.run(@ip, answer) do
      [addr] ->
        if private_address?(addr), do: {:ok, addr}, else: :error

      _ ->
        :error
    end
  end

  defp private_address?(addr) do
    case Repo.query!("SELECT swarm_net_address_class(swarm_try_inet($1))", [addr]) do
      %{rows: [["private"]]} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
