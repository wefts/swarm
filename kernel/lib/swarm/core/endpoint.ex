defmodule Swarm.Core.Endpoint do
  @moduledoc "gRPC endpoint exposing the Core API to channel adapters."

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)
  run(Swarm.Core.Server)
end
