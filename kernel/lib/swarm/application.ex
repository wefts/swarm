defmodule Swarm.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Swarm.Repo,
      # Connection supervisor for the gRPC client to the Python ML pillar.
      {GRPC.Client.Supervisor, []}
    ]

    # one_for_one: a child crash restarts only that child — graceful degradation,
    # not a swarm-wide outage.
    opts = [strategy: :one_for_one, name: Swarm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
