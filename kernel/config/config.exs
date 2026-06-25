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

# Hybrid retrieval (swarm ADR-14 §5). `floor` is the absolute-cosine relevance gate
# (dense-only hits below it are out-of-scope → `:not_found`). `dense` toggles the
# vector arm; the test env has no embedding sidecar (and no embedded chunks), so it
# runs lexical-only — disabled below — to avoid an unreachable-ML round-trip per query.
# `lex_weight`/`dense_weight` are the weighted-RRF arm weights (Card 7): lex_weight=3
# floors exact keyword hits so a dense "magnet" cannot demote them, while leaving
# paraphrase ranking untouched (paraphrase queries have no lexical rows). Tuned on the
# 2-source slice — verbatim MRR 0.69→0.88, paraphrase recall held ~70%.
config :swarm, :retrieval, floor: 0.45, dense: true, lex_weight: 3.0, dense_weight: 1.0

if config_env() == :test do
  config :swarm, :retrieval, floor: 0.45, dense: false, lex_weight: 3.0, dense_weight: 1.0
end

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
  judge: "llama3.3:70b",
  # Per-escalation token ceiling (T5, ADR-7). An escalation whose prompt exceeds
  # this is refused fail-loud — never silently truncated — so a raw tool/source
  # payload cannot reach a model (the glpi 385k-token scar).
  token_ceiling: 32_000

# Hard per-call ceiling at the model boundary (T5, ADR-7): the GLOBAL backstop.
# Every `Swarm.ML.Generation.generate/3` call — from ANY caller, not just the
# consilium — is refused fail-loud above this. Set higher than the consilium
# per-escalation ceiling so the consilium is the tighter, earlier refusal.
config :swarm, :llm, max_prompt_tokens: 64_000

# Core API: the gRPC endpoint a Channel adapter (CLI, web) speaks to (Domain 11).
config :swarm, :core_api, port: 50061, start_server: true

# Stigmergy tailer (swarm ADR-2): the single reader of the graph-change outbox.
# `poll_ms` is the fallback cadence; LISTEN/NOTIFY drives the low-latency path.
config :swarm, :stigmergy, enabled: true, poll_ms: 1_000, gap_ms: 2_000

# Trace GC (swarm ADR-9 / T11): reap evaporated traces hourly. `floor` is the
# decayed-strength below which a trace is noise — re-derive per corpus scale.
config :swarm, :gc, enabled: true, interval_ms: 3_600_000, floor: 0.05

# Stagnation watchdog (swarm ADR-12 / T13): surface unclaimed coordination traces
# every 10 min; `ttl_s` is the age past which an unclaimed trace is a stalled claim.
config :swarm, :stagnation, enabled: true, interval_ms: 600_000, ttl_s: 3_600

# Reward-gated enrichment (workspace ADR-13 / EOS-4): the LOCAL model the worker
# drives for S-P-O extraction, the policy version that invalidates watermarks when
# the extraction prompt/parse changes, and the passage cap fed to the model.
# Extraction is rare + deliberate (~120 s/source) — never the continuous default.
config :swarm, :enrichment,
  model: "qwen3:14b",
  policy_version: 1,
  max_passage: 2_400,
  # Prior reliability of a single unverified LLM claim (ADR-3): plausible, not
  # certain. Corroboration collapses repeated claims (combine_typed), and external
  # reward later confirms/refutes (ADR-11); this is the entering prior, not truth.
  claim_reliability: 0.5
