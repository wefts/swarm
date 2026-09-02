defmodule Swarm.WorldMap.SemanticRouter do
  @moduledoc """
  Semantic front-end for the world-map gate.

  Regex cues remain the first, cheapest signal. This module is the fallback for
  paraphrases the cue lexicon misses: embed the query and compare it with a small,
  domain-owned exemplar set. It returns the query vector too so candidate lookup
  can use the same embedding instead of paying twice.
  """

  alias Swarm.ML.Embeddings

  @type route :: :procedure | {:neighborhood, atom()} | :none
  @type result :: %{route: route(), score: float(), query_vec: [float()] | nil}

  @threshold 0.50

  @exemplars [
    {:procedure, "how do I reset an account password"},
    {:procedure, "steps to configure a service"},
    {:procedure, "procedure to restart an application"},
    {{:neighborhood, :network}, "what is the ip address of a site"},
    {{:neighborhood, :network}, "what is the private ip address of a site"},
    {{:neighborhood, :network}, "which public outbound ip does a service use"},
    {{:neighborhood, :network}, "what subnet is behind a gateway"},
    {{:neighborhood, :network}, "which hosts route through this gateway"},
    {{:neighborhood, :who}, "who manages this team"},
    {{:neighborhood, :who}, "who runs this service"},
    {{:neighborhood, :who}, "who should I contact for a service"},
    {{:neighborhood, :who}, "who looks after a service"},
    {{:neighborhood, :who}, "which people are in this group"},
    {{:neighborhood, :technology}, "what is known about this technology"},
    {{:neighborhood, :technology}, "which documents mention this framework"},
    {{:neighborhood, :technology}, "which services use this runtime"}
  ]

  @doc """
  Return a semantic route for `query`, or `:none` when embeddings are unavailable
  or no exemplar clears the threshold. `:embed_fun` is injectable for tests.
  """
  @spec route(String.t(), keyword()) :: result()
  def route(query, opts \\ []) when is_binary(query) do
    texts = [query | Enum.map(@exemplars, &elem(&1, 1))]

    with {:ok, [qvec | exemplar_vecs]} <- embed(texts, opts),
         {route, score} <- best(qvec, exemplar_vecs),
         true <- score >= Keyword.get(opts, :semantic_gate_threshold, @threshold) do
      %{route: route, score: score, query_vec: qvec}
    else
      _ -> %{route: :none, score: 0.0, query_vec: nil}
    end
  end

  defp embed(texts, opts) do
    case Keyword.get(opts, :semantic_embed_fun) do
      fun when is_function(fun, 1) ->
        fun.(texts)

      _ ->
        case Embeddings.embed(texts) do
          {:ok, %{vectors: vectors}} -> {:ok, vectors}
          other -> other
        end
    end
  end

  defp best(qvec, exemplar_vecs) do
    @exemplars
    |> Enum.zip(exemplar_vecs)
    |> Enum.map(fn {{route, _text}, vec} -> {route, cosine(qvec, vec)} end)
    |> Enum.max_by(fn {_route, score} -> score end, fn -> {:none, 0.0} end)
  end

  defp cosine(a, b) do
    {dot, an, bn} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, an, bn} ->
        {dot + x * y, an + x * x, bn + y * y}
      end)

    denom = :math.sqrt(an) * :math.sqrt(bn)
    if denom == 0.0, do: 0.0, else: dot / denom
  end
end
