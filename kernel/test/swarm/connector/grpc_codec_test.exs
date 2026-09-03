defmodule Swarm.Connector.GrpcCodecTest do
  use ExUnit.Case, async: true

  alias Swarm.Connector.GrpcCodec
  alias Swarm.Connector.V1.{FetchResponse, FetchStatus}

  test "round-trips a fetch page without changing connector semantics" do
    event = %{
      provenance: "mediawiki:11",
      origin: "mediawiki:11",
      source: "mediawiki",
      source_ref: "mediawiki:11",
      occurred_at: ~U[2024-03-02 10:15:30Z],
      entities: [
        %{type: "article", key: "Runbook Deploy", scope: "src:wiki", content: "Deploy steps"},
        %{type: "article", key: "Rollback", identity: "mediawiki:12", scope: "src:wiki"}
      ],
      relations: [
        %{from: "Runbook Deploy", to: "Rollback", type: "links_to", to_ref: "mediawiki:12"}
      ]
    }

    skip = %{
      connector: "Hive.MediaWiki.Connector",
      source: "mediawiki",
      source_ref: "mediawiki:99",
      reason: "namespace_filtered",
      occurred_at: ~U[2024-03-02 10:15:30Z]
    }

    response = %FetchResponse{
      status: FetchStatus.value(:FETCH_OK),
      page:
        GrpcCodec.encode_page(%{
          events: [event],
          cursor: %{"__page" => 2, "gapcontinue" => "Next"},
          truncated?: true,
          skips: [skip],
          total: 17
        })
    }

    assert {:ok, page} = GrpcCodec.page(response)
    assert page.cursor == %{"__page" => 2, "gapcontinue" => "Next"}
    assert page.truncated?
    assert page.total == 17

    assert [%{origin: "mediawiki:11", occurred_at: "2024-03-02T10:15:30Z", valid_time: nil}] =
             page.events

    assert [%{reason: "namespace_filtered", source_ref: "mediawiki:99"}] = page.skips
  end

  test "carries the optional valid_time (temporal model) and leaves it nil when absent" do
    timed = %{
      provenance: "proxmox:casa:vm:101@2026-09-03T10:00:00Z",
      origin: "proxmox:casa:vm:101",
      source: "proxmox:casa",
      occurred_at: ~U[2026-09-03 10:00:00Z],
      valid_time: ~U[2026-09-03 10:00:00Z],
      entities: [],
      relations: []
    }

    response = %FetchResponse{
      status: FetchStatus.value(:FETCH_OK),
      page: GrpcCodec.encode_page(%{events: [timed], cursor: :done})
    }

    assert {:ok, %{events: [%{valid_time: "2026-09-03T10:00:00Z", source: "proxmox:casa"}]}} =
             GrpcCodec.page(response)
  end

  test "accepts protobuf enum atoms from decoded grpc responses" do
    response = %FetchResponse{
      status: :FETCH_OK,
      page: GrpcCodec.encode_page(%{events: [], cursor: :done})
    }

    assert {:ok, %{cursor: :done}} = GrpcCodec.page(response)
  end
end
