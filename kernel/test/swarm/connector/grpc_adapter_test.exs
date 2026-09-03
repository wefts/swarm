defmodule Swarm.Connector.GrpcAdapterTest do
  use ExUnit.Case, async: true

  alias Swarm.Connector.GrpcAdapter
  alias Swarm.Connector.GrpcCodec
  alias Swarm.Connector.V1.{FetchResponse, FetchStatus}

  test "fetch/2 calls the remote fetch RPC with encoded options" do
    fetch = fn request ->
      assert request.cursor.start
      assert request.options.scope == "src:wiki"
      assert request.options.max_pages == 7
      assert request.options.source_options == %{"gaplimit" => "30"}

      {:ok,
       %FetchResponse{
         status: FetchStatus.value(:FETCH_OK),
         page: GrpcCodec.encode_page(%{events: [], cursor: :done, truncated?: false})
       }}
    end

    assert {:ok, %{events: [], cursor: :done, truncated?: false}} =
             GrpcAdapter.fetch(:start,
               scope: "src:wiki",
               max_pages: 7,
               gaplimit: 30,
               fetch_fun: fetch
             )
  end
end
