defmodule Swarm.Connector.GrpcAdapter do
  @moduledoc """
  `Swarm.Ports.Connector` adapter for an out-of-process ADR-21 connector.

  The adapter is intentionally thin: it turns `fetch/2` calls into gRPC requests
  and lets `Swarm.Connector.Sync` keep ownership of pagination, truncation,
  retries, skip-ledger writes, and ingest.
  """

  @behaviour Swarm.Ports.Connector

  alias Swarm.Connector.GrpcCodec
  alias Swarm.Connector.V1.Connector.Stub

  @impl true
  def describe do
    %{name: "connector_grpc", kind: :connector, source: "remote", sync_modes: [:full, :delta]}
  end

  @impl true
  def fetch(cursor, opts) do
    request = GrpcCodec.request(cursor, opts)

    with {:ok, response} <- call_fetch(request, opts) do
      GrpcCodec.page(response)
    end
  end

  defp call_fetch(request, opts) do
    cond do
      fetch_fun = Keyword.get(opts, :fetch_fun) ->
        fetch_fun.(request)

      channel = Keyword.get(opts, :channel) ->
        Stub.fetch(channel, request, timeout: Keyword.get(opts, :timeout, 30_000))

      true ->
        with {:ok, channel} <- connect(opts) do
          Stub.fetch(channel, request, timeout: Keyword.get(opts, :timeout, 30_000))
        end
    end
  end

  defp connect(opts) do
    address = Keyword.fetch!(opts, :address)
    connect_fun = Keyword.get(opts, :connect_fun, &GRPC.Stub.connect/2)

    connect_fun.(address, [])
  end
end
