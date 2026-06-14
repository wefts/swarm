defmodule Swarm.ML.EmbeddingsTest do
  use ExUnit.Case, async: true

  # Cross-language end-to-end: requires the Python ML service to be running
  # (`uv run swarm-ml` in ml/). Excluded by default; run with
  # `mix test --include integration`.
  @moduletag :integration

  alias Swarm.ML.Embeddings

  test "embed/2 calls the Python Embed RPC and gets vectors back" do
    assert {:ok, result} = Embeddings.embed(["hello", "світ"])
    assert is_integer(result.dim) and result.dim > 0
    assert length(result.vectors) == 2
    assert Enum.all?(result.vectors, &(length(&1) == result.dim))
  end
end
