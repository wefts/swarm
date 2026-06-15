import Config

# Compile-time config. Connection details are env-driven and live in
# runtime.exs (no secrets committed); this file only declares the repo.
config :swarm, ecto_repos: [Swarm.Repo]

# pgvector support: the Repo speaks the `vector` type via a custom Postgrex
# types module (see Swarm.PostgrexTypes).
config :swarm, Swarm.Repo, types: Swarm.PostgrexTypes

# Embedding dimensionality of the `node.vec` column (ADR-6). One model/space at
# a time; changing it is a re-embed migration, not an in-place edit. 1024 =
# bge-m3 (multilingual UA/FR/EN), the chosen embedding model (Task 03).
config :swarm, :embedding, dim: 1024

# Decay + saturation parameters (ADR-9). These belong to the tuning inventory
# (ADR-8) — measured, not intuited; defaults here are placeholders until
# calibrated. `lambda` is per-day decay; `saturation_s` is the Hill constant S.
config :swarm, :decay, lambda: 0.01, saturation_s: 2.0
