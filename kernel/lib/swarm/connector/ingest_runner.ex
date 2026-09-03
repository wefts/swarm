defmodule Swarm.Connector.IngestRunner do
  @moduledoc """
  Release-callable runner for scheduled ADR-21 connector ingestion.

  A scheduler starts the kernel image beside one connector image. This runner
  connects to the connector's localhost gRPC server and delegates the pagination
  loop to `Swarm.Connector.Sync`.
  """

  alias Swarm.Connector.{GrpcAdapter, Sync}

  @spec run(keyword()) :: {:ok, Sync.report()} | {:error, term()}
  def run(opts) do
    opts = defaults(opts)

    with :ok <- start_runtime(),
         {:ok, channel} <- connect(opts) do
      opts =
        opts
        |> Keyword.put(:channel, channel)
        |> Keyword.delete(:address)

      Sync.run(GrpcAdapter, opts)
    end
  end

  @spec run_from_env() :: {:ok, Sync.report()} | {:error, term()}
  def run_from_env do
    :ok = start_runtime()

    run(
      address: env!("SWARM_CONNECTOR_ADDRESS"),
      scope: scope(),
      max_pages: int_env("WIKI_MAXPAGES", 30),
      gaplimit: int_env("WIKI_GAPLIMIT", 50)
    )
  end

  defp defaults(opts) do
    opts
    |> Keyword.put_new(:address, "127.0.0.1:50071")
    |> Keyword.put_new(:timeout, 60_000)
  end

  defp start_runtime do
    with {:ok, _} <- Application.ensure_all_started(:swarm) do
      :ok
    end
  end

  defp connect(opts) do
    address = Keyword.fetch!(opts, :address)
    connect_fun = Keyword.get(opts, :connect_fun, &GRPC.Stub.connect/2)

    connect_fun.(address, [])
  end

  defp scope do
    case System.get_env("WIKI_SOURCE_ID") do
      nil -> Swarm.Projects.scope_by_kind!("wiki")
      "" -> Swarm.Projects.scope_by_kind!("wiki")
      source_id -> Swarm.Projects.scope!(source_id)
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      nil -> raise "missing required env #{name}"
      "" -> raise "missing required env #{name}"
      value -> value
    end
  end

  defp int_env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end
end
