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

if config_env() == :test do
  config :logger, level: :warning
  # Unit tests call the Core logic directly; don't bind the gRPC server port.
  config :swarm, :core_api, port: 50061, start_server: false
end
