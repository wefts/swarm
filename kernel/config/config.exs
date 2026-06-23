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

# Consilium fleet (Domain 4): a mid-tier panel answers in parallel; a stronger,
# different-family judge synthesizes. Models are reached over the ML boundary
# (Ollama). The judge should differ from the panel majority to decorrelate
# blind spots (ADR-7 confident-wrong mitigation).
config :swarm, :consilium,
  panel: ["qwen3.6:35b", "qwen3:14b", "gemma4:31b", "glm-4.7-flash"],
  judge: "llama3.3:70b"

# Core API: the gRPC endpoint a Channel adapter (CLI, web) speaks to (Domain 11).
config :swarm, :core_api, port: 50061, start_server: true

# Stigmergy tailer (swarm ADR-2): the single reader of the graph-change outbox.
# `poll_ms` is the fallback cadence; LISTEN/NOTIFY drives the low-latency path.
config :swarm, :stigmergy, enabled: true, poll_ms: 1_000, gap_ms: 2_000
