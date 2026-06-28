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

database =
  case config_env() do
    :test -> System.get_env("SWARM_DB_NAME", "swarm_test")
    _ -> System.get_env("SWARM_DB_NAME", "swarm_dev")
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
