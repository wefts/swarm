defmodule Swarm.Repo do
  @moduledoc """
  The kernel's Ecto repo over Postgres + pgvector (storage decided by the spike,
  see `docs/storage_engine_spike.md`). Connection config is env-driven in
  `config/runtime.exs`.
  """

  use Ecto.Repo,
    otp_app: :swarm,
    adapter: Ecto.Adapters.Postgres
end
