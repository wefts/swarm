defmodule Swarm.Gate.Matcher do
  @moduledoc """
  Routing **mechanism**: cosine 1-NN of a message to the intent prototypes. It
  returns a RAW score and the matched intent/tier; band/threshold policy lives in
  `Swarm.Gate.Bands`. The embedder is injectable (default: `bge-m3` via the ML
  boundary) so tests stay hermetic.

  Performance: O(P) cosines over a fixed small prototype set P, each O(d) in the
  embedding dim — constant in graph size.
  """

  alias Swarm.Gate.Prototypes
  alias Swarm.ML.Embeddings

  @type match :: %{intent: atom(), tier: :tier0 | :tier_tools, score: float()}
  @type embedder :: (String.t() -> {:ok, [float()]} | {:error, term()})

  @doc "Score a message: `{:ok, match}` (raw cosine) or `{:error, reason}` (embedder down)."
  @spec score(String.t(), keyword()) :: {:ok, match()} | {:error, term()}
  def score(message, opts \\ []) do
    embedder = Keyword.get(opts, :embedder, &default_embed/1)
    prototypes = Keyword.get(opts, :prototypes, Prototypes.all())

    with {:ok, mvec} <- embedder.(message),
         {:ok, pvecs} <- embed_all(prototypes, embedder) do
      {:ok, nearest(mvec, Enum.zip(prototypes, pvecs))}
    end
  end

  @doc """
  Keyword fallback for graceful degradation when embeddings are unavailable.
  Conservative floor: unknown intent → `:escalate` (bias to escalate under doubt).
  """
  @spec keyword_fallback(String.t()) :: :tier0 | :tier_tools | :escalate
  def keyword_fallback(message) do
    m = String.downcase(message)

    cond do
      Regex.match?(~r/\b(hi|hello|hey|thanks|bye)\b/, m) -> :tier0
      Regex.match?(~r/\b(status|find|show|list|recent|changed)\b/, m) -> :tier_tools
      true -> :escalate
    end
  end

  @doc "Cosine similarity of two equal-length vectors; 0.0 if either is a zero vector."
  @spec cosine([float()], [float()]) :: float()
  def cosine(a, b) do
    dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    na = norm(a)
    nb = norm(b)
    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (na * nb)
  end

  @spec norm([float()]) :: float()
  defp norm(v), do: :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end))

  @spec embed_all([Prototypes.prototype()], embedder()) :: {:ok, [[float()]]} | {:error, term()}
  defp embed_all(prototypes, embedder) do
    result =
      Enum.reduce_while(prototypes, [], fn p, acc ->
        case embedder.(p.text) do
          {:ok, vec} -> {:cont, [vec | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err -> err
      vecs -> {:ok, Enum.reverse(vecs)}
    end
  end

  @spec nearest([float()], [{Prototypes.prototype(), [float()]}]) :: match()
  defp nearest(mvec, proto_vecs) do
    {proto, sim} =
      proto_vecs
      |> Enum.map(fn {p, v} -> {p, cosine(mvec, v)} end)
      |> Enum.max_by(fn {_p, sim} -> sim end)

    %{intent: proto.intent, tier: proto.tier, score: sim}
  end

  @spec default_embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  defp default_embed(text) do
    case Embeddings.embed([text]) do
      {:ok, %{vectors: [vec | _]}} -> {:ok, vec}
      {:ok, _} -> {:error, :no_vector}
      {:error, _} = err -> err
    end
  end
end
