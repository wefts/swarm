# Custom Postgrex types so the Repo speaks pgvector's `vector` type. Defined as
# a bare module-defining call per the pgvector-elixir convention; referenced by
# `config :swarm, Swarm.Repo, types: Swarm.PostgrexTypes`.
Postgrex.Types.define(
  Swarm.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
