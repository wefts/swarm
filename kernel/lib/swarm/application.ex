defmodule Swarm.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Swarm.Repo,
      # Connection supervisor for the gRPC client to the Python ML pillar.
      {GRPC.Client.Supervisor, []},
      # Ingestion (Domain 2): dedup pre-filter, bounded queue, plugin registry.
      Swarm.Ingest.Dedup,
      Swarm.Ingest.Queue,
      Swarm.Plugins.Registry,
      # Gate (Domain 5): cost telemetry counters.
      Swarm.Gate.Telemetry
    ]

    # one_for_one: a child crash restarts only that child — graceful degradation,
    # not a swarm-wide outage.
    opts = [strategy: :one_for_one, name: Swarm.Supervisor]
    Supervisor.start_link(children ++ core_api(), opts)
  end

  # The outward Core API gRPC server (Domain 11) — disabled in tests, which call
  # the Core logic directly.
  defp core_api do
    cfg = Application.get_env(:swarm, :core_api, [])

    if Keyword.get(cfg, :start_server, false) do
      [
        {GRPC.Server.Supervisor,
         endpoint: Swarm.Core.Endpoint, port: Keyword.fetch!(cfg, :port), start_server: true}
      ]
    else
      []
    end
  end
end
