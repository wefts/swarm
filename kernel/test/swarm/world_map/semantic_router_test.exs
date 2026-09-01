defmodule Swarm.WorldMap.SemanticRouterTest do
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.SemanticRouter

  defp vec(:network), do: [1.0, 0.0, 0.0]
  defp vec(:who), do: [0.0, 1.0, 0.0]
  defp vec(:procedure), do: [0.0, 0.0, 1.0]
  defp vec(:none), do: [0.0, 0.0, 0.0]

  defp fake_embed(route_for_query) do
    fn [query | exemplars] ->
      qvec = vec(Map.fetch!(route_for_query, query))

      exemplar_vecs =
        Enum.map(exemplars, fn text ->
          cond do
            String.contains?(text, "private ip") -> vec(:network)
            String.contains?(text, "outbound ip") -> vec(:network)
            String.contains?(text, "subnet") -> vec(:network)
            String.contains?(text, "hosts route") -> vec(:network)
            String.contains?(text, "manages") -> vec(:who)
            String.contains?(text, "runs this service") -> vec(:who)
            String.contains?(text, "contact") -> vec(:who)
            String.contains?(text, "looks after") -> vec(:who)
            String.contains?(text, "people") -> vec(:who)
            true -> vec(:procedure)
          end
        end)

      {:ok, [qvec | exemplar_vecs]}
    end
  end

  describe "route/2" do
    test "held-out network paraphrases route semantically without a regex cue" do
      routes = %{
        "How is the site addressed internally?" => :network,
        "Which egress address do the runners use?" => :network
      }

      for query <- Map.keys(routes) do
        assert %{
                 route: {:neighborhood, :network},
                 query_vec: query_vec,
                 score: score
               } =
                 SemanticRouter.route(query,
                   semantic_embed_fun: fake_embed(routes),
                   semantic_gate_threshold: 0.5
                 )

        assert query_vec == vec(:network)
        assert score >= 0.5
      end
    end

    test "held-out who and procedure paraphrases route to their own domains" do
      routes = %{
        "Who should I contact for this service?" => :who,
        "Walk me through rotating a credential" => :procedure
      }

      assert %{route: {:neighborhood, :who}} =
               SemanticRouter.route("Who should I contact for this service?",
                 semantic_embed_fun: fake_embed(routes),
                 semantic_gate_threshold: 0.5
               )

      assert %{route: :procedure} =
               SemanticRouter.route("Walk me through rotating a credential",
                 semantic_embed_fun: fake_embed(routes),
                 semantic_gate_threshold: 0.5
               )
    end

    test "embedding failure fails closed" do
      assert %{route: :none, query_vec: nil, score: score} =
               SemanticRouter.route("anything", semantic_embed_fun: fn _ -> {:error, :down} end)

      assert score == 0.0
    end
  end
end
