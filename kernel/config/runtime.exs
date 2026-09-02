import Config

# DB connection is env-driven: local and Spark differ only by environment, never
# by committed values. Defaults match dev/docker-compose.yml for local dev;
# real secrets come from the environment, never from this file.
repo_opts = [
  username: System.get_env("SWARM_DB_USER", "swarm"),
  password: System.get_env("SWARM_DB_PASSWORD", "swarm"),
  hostname: System.get_env("SWARM_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("SWARM_DB_PORT", "5432")),
  pool_size: String.to_integer(System.get_env("SWARM_DB_POOL_SIZE", "10"))
]

# ADR-0015: SWARM_ENV ∈ {test, staging, prod} derives the database name
# (`swarm_#{SWARM_ENV}`) — no hardcoded fallback. An explicit SWARM_DB_NAME
# always wins outright (sandbox clones — swarm_slice, swarm_shadow, ad hoc
# restores — name themselves and never derive). Outside :test, an unset
# SWARM_ENV (and no explicit override) is a hard boot error: there is no more
# silent "swarm_dev" target, which is what retires the "conditional-prod" guard.
#
# Council finding (codex): System.get_env/1 returns "" for an explicitly-set-
# but-blank var, which `is_binary` would treat as a real value — blank(_/1)
# below normalizes "" to nil so it can never silently win or derive "swarm_".
blank = fn
  nil -> nil
  "" -> nil
  s -> s
end

database =
  case {config_env(), blank.(System.get_env("SWARM_DB_NAME")),
        blank.(System.get_env("SWARM_ENV"))} do
    {_, explicit, _} when is_binary(explicit) ->
      explicit

    # :test is hermetic by construction (wiped every run, ADR-14 "test" role) —
    # ALWAYS swarm_test, ignoring SWARM_ENV entirely (council finding: a stray
    # SWARM_ENV=staging in the shell must never leak into a "hermetic" test run).
    {:test, nil, _} ->
      "swarm_test"

    {_, nil, env} when is_binary(env) ->
      "swarm_#{env}"

    {_, nil, nil} ->
      raise """
      SWARM_ENV is not set. Refusing to guess a database (ADR-14: test | \
      staging | prod). Set SWARM_ENV, or set SWARM_DB_NAME directly for a \
      sandbox clone.
      """
  end

# The concurrent-claim test runs many parallel writers (no SQL sandbox); give
# the test pool headroom so claims contend in Postgres, not on checkout.
repo_opts =
  if config_env() == :test do
    Keyword.put(
      repo_opts,
      :pool_size,
      String.to_integer(System.get_env("SWARM_DB_POOL_SIZE", "25"))
    )
  else
    repo_opts
  end

config :swarm, Swarm.Repo, [{:database, database} | repo_opts]

# Consilium model fleet — overridable at deploy time. The default decorrelated
# heavy panel + strong judge live in config.exs (the product default); a
# deployment whose hardware cannot swap big models fast — e.g. a single-GPU dev
# box where a 5-model panel + 70B judge serialize into minutes — overrides these
# with small, GPU-resident models for a responsive answer. Comma-separated panel;
# single judge. These deep-merge with the config.exs :consilium block (token
# ceiling etc. preserved). Unset ⇒ the product default stands.
if panel = System.get_env("SWARM_CONSILIUM_PANEL") do
  config :swarm, :consilium,
    panel: panel |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

if judge = System.get_env("SWARM_CONSILIUM_JUDGE") do
  config :swarm, :consilium, judge: judge
end

# Enrichment reward-gate threshold — the ADR-8 tuning knob, calibrated PER CORPUS
# (calibrate.exs). The config.exs default (0.35) gates little; a calibrated run sets
# SWARM_ENRICH_THRESHOLD to its corpus p50 (prod ≈ 0.58, derived 2026-06-29) so
# enrichment is selective. Deep-merges into the :enrichment priority — the weights
# (w_central/w_crit/central_k) are preserved. Unset ⇒ the product default stands.
if threshold = System.get_env("SWARM_ENRICH_THRESHOLD") do
  config :swarm, :enrichment, priority: [threshold: String.to_float(threshold)]
end

# Entity-resolution vector gate — the ADR-8 / CTC-5 finding-#3 tuning knob, calibrated
# PER CORPUS and **UPWARD-only** (the entity_resolution_audit can justify raising the
# gate, never lowering — below-gate merges are unobserved; `calibrate.exs`). The
# config.exs default (0.85) over-proposes on a real corpus (wasted LLM confirms); a
# deployment raises SWARM_ER_VEC_THRESHOLD to tighten the vector arm (prod ≈ 0.90,
# derived 2026-06-30). Merges into :entity_resolution — lex_threshold/max_pairs are
# preserved. Unset ⇒ the product default stands.
if er_vec = System.get_env("SWARM_ER_VEC_THRESHOLD") do
  config :swarm, :entity_resolution, vec_threshold: String.to_float(er_vec)
end

# ADR-17 tier-gate (Fork B): serve covered asks from pre-built structure before the
# consilium. OFF unless EXPLICITLY enabled — a false-serve breaks trust, so it ships off
# until the go/no-go (`board/todo/tier-gate-gonogo.md`) shows false_serve_rate ~0 (measured
# on `Swarm.WorldMap.Gate.Calibration`). `SWARM_TIER_GATE_ENTAIL_MODEL` overrides the Stage-2
# entail model (default gemma4:31b — the resident judge; fsr 0.0 / recall 1.0 on the eval).
if System.get_env("SWARM_TIER_GATE_ENABLED") == "true" do
  config :swarm, :tier_gate, enabled: true
end

# NB: `if "" do` is TRUTHY in Elixir — an UNSET compose var arrives as "" and must be treated
# as absent, else the gate gets an empty model name.
case System.get_env("SWARM_TIER_GATE_ENTAIL_MODEL") do
  m when is_binary(m) and m != "" -> config :swarm, :tier_gate, entail_model: m
  _ -> :ok
end

# The :network serve path (topology neighborhoods) — OFF unless explicitly enabled, its OWN
# go/no-go separate from the procedure gate. Calibrated on `Swarm.WorldMap.Gate.NetworkCalibration`
# (fsr 0.0 / recall 1.0, gemma4:31b) + live-verified; serves only CORROBORATED (>=2-origin)
# topology, so a false-serve stays unrepresentable. Widen the corroboration floor to 1 only after
# floor-2 proves safe live.
if System.get_env("SWARM_TIER_GATE_NETWORK_SERVE") == "true" do
  config :swarm, :tier_gate, network_serve: true
end

# The :who serve path (org-directory who-is-who, E1) — OFF unless explicitly enabled, its OWN
# go/no-go. Calibrated on `Swarm.WorldMap.Gate.WhoCalibration` (fsr 0.0 / recall 1.0, gemma4:31b).
# Serves an AUTHORITATIVE single-source directory at min_corroboration 1 — safe because the
# substrate is kept current by full-state RECONCILIATION (each refresh purges + rebuilds), so a
# departed/moved person can't be served stale.
if System.get_env("SWARM_TIER_GATE_WHO_SERVE") == "true" do
  config :swarm, :tier_gate, who_serve: true
end

# The :technology serve path is a read-only structural projection over existing scoped corpus
# evidence. It stays OFF unless explicitly enabled, like every neighborhood domain.
if System.get_env("SWARM_TIER_GATE_TECHNOLOGY_SERVE") == "true" do
  config :swarm, :tier_gate, technology_serve: true
end

# Corroboration floor for the network serve path (default 2 = only multi-source-confirmed;
# 1 = any ground-truth fact, wider coverage leaning on the Stage-2 entail veto). Empty/unset ⇒
# the code default (2). Widen to 1 only after floor-2 proves safe live (network-serve-path-gonogo).
case System.get_env("SWARM_TIER_GATE_NETWORK_MIN_CORROB") do
  n when is_binary(n) and n != "" ->
    config :swarm, :tier_gate, network_min_corroboration: String.to_integer(n)

  _ ->
    :ok
end

case System.get_env("SWARM_TIER_GATE_TECHNOLOGY_MIN_CORROB") do
  n when is_binary(n) and n != "" ->
    config :swarm, :tier_gate, technology_min_corroboration: String.to_integer(n)

  _ ->
    :ok
end

# Lexical retrieval engine (ADR-0016) — a rebuild-free flip / rollback between the
# pg_search BM25 arm (`bm25`, the shipped default) and the retained native `ts_rank`
# arm (`native`). Set `SWARM_LEXICAL_ENGINE=native` to roll back instantly at deploy
# (e.g. if a pg_search issue appears), or on a Postgres without the extension. Merges
# into :retrieval — the other keys (floor/weights/boost) are preserved. Unset ⇒ the
# product default (`:bm25`) stands.
if engine = System.get_env("SWARM_LEXICAL_ENGINE") do
  config :swarm, :retrieval, lexical_engine: String.to_atom(engine)
end

# Verified-actor shared secret (ADR-16 D9). The channel (hive) and kernel share it
# (single box; `hive/secrets.env`, gitignored). Env-only — never committed. Absent ⇒
# the kernel cannot verify an assertion and fails closed on security paths.
if secret = System.get_env("SWARM_ACTOR_SECRET") do
  config :swarm, :actor, secret: secret
end

# Core API auth mode (ADR-16 D9). `SWARM_AUTH_MODE` overrides the compiled default.
# Unset ⇒ the product default (`:strict`, config.exs) stands — verified identity only.
# Set `dual`/`legacy` ONLY as an explicit migration opt-in (dual makes `viewer` forgeable
# — see `dual-mode-history-leak`). Merges into :core_api.
case System.get_env("SWARM_AUTH_MODE") do
  m when m in ["dual", "strict", "legacy"] ->
    config :swarm, :core_api, auth_mode: String.to_existing_atom(m)

  nil ->
    :ok

  other ->
    raise "SWARM_AUTH_MODE=#{inspect(other)} invalid — expected dual | strict | legacy"
end

# Elevation knobs (ADR-20). Blank/unset ⇒ the config.exs defaults stand.
case System.get_env("SWARM_ELEVATION_TTL_S") do
  v when is_binary(v) and v != "" ->
    config :swarm, :elevation, default_ttl_s: String.to_integer(v)

  _ ->
    :ok
end

case System.get_env("SWARM_ELEVATION_MAX_TTL_S") do
  v when is_binary(v) and v != "" -> config :swarm, :elevation, max_ttl_s: String.to_integer(v)
  _ -> :ok
end

# The default internal cohort group (ADR-20 "Staff"); set to "" to disable auto-joining.
case System.get_env("SWARM_DEFAULT_COHORT_GROUP") do
  nil -> :ok
  v -> config :swarm, :identity, default_cohort: String.trim(v)
end

if config_env() == :test do
  config :logger, level: :warning
  # Unit tests call the Core logic directly; don't bind the gRPC server port.
  config :swarm, :core_api, port: 50061, start_server: false
  # Unit tests never reach a live ML service; don't start the channel pool (it
  # would crash-loop reconnects against an absent ml:50051). The boundary is
  # tested with an injected connect fun instead.
  config :swarm, :ml_pool, enabled: false
  # Tests drive a tailer instance directly; no global tailer racing on the outbox.
  config :swarm, :stigmergy, enabled: false
  # Tests call Swarm.Graph.GC.reap/1 directly; no global GC reaping under them.
  config :swarm, :gc, enabled: false
  # Tests call Swarm.Coordination.Stagnation.scan_stalls/1 directly.
  config :swarm, :stagnation, enabled: false
end
