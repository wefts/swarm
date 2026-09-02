defmodule Mix.Tasks.Swarm.TopologyJoin do
  @shortdoc "Derive network topology joins and identity bridges"

  @moduledoc """
  Derives WAN↔compute joins and exact identity bridges from existing graph facts.
  Writes must target a sandbox clone via `SWARM_DB_NAME`; `swarm_staging` is
  refused for `--apply` unless a deliberate operator write includes
  `--allow-staging`.

  Examples:

      mix swarm.topology_join --scopes src:...
      SWARM_DB_NAME=swarm_structural_spine_sandbox mix swarm.topology_join --scopes src:... --apply
      SWARM_ENV=staging mix swarm.topology_join --scopes src:... --apply --allow-staging
      mix swarm.topology_join --scopes src:... --gateway net:gateway:gateway-a
  """

  use Mix.Task

  alias Swarm.Enrichment.TopologyJoin
  alias Swarm.Repo

  @switches [
    apply: :boolean,
    allow_staging: :boolean,
    scopes: :string,
    gateway: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, switches: @switches)
    start_repo!()
    refuse_staging_apply!(opts)
    warn_staging_apply!(opts)

    scopes = scopes!(opts)
    summary = TopologyJoin.derive(scopes, apply: Keyword.get(opts, :apply, false))

    Mix.shell().info("topology_join.summary=" <> inspect(summary))

    case Keyword.get(opts, :gateway) do
      nil -> :ok
      gateway -> print_gateway_tree(gateway, scopes)
    end
  end

  defp start_repo! do
    configure_repo_from_env()
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp configure_repo_from_env do
    cfg = Application.get_env(:swarm, Repo, [])

    if Keyword.get(cfg, :database) do
      :ok
    else
      database =
        System.get_env("SWARM_DB_NAME") ||
          case System.get_env("SWARM_ENV") do
            nil ->
              Mix.raise("set SWARM_DB_NAME to a sandbox clone, or SWARM_ENV for read-only use")

            "" ->
              Mix.raise("set SWARM_DB_NAME to a sandbox clone, or SWARM_ENV for read-only use")

            env ->
              "swarm_#{env}"
          end

      repo_opts = [
        database: database,
        username: System.get_env("SWARM_DB_USER", "swarm"),
        password: System.get_env("SWARM_DB_PASSWORD", "swarm"),
        hostname: System.get_env("SWARM_DB_HOST", "localhost"),
        port: System.get_env("SWARM_DB_PORT", "5432") |> String.to_integer(),
        pool_size: System.get_env("SWARM_DB_POOL_SIZE", "10") |> String.to_integer()
      ]

      Application.put_env(:swarm, Repo, Keyword.merge(cfg, repo_opts))
    end
  end

  defp scopes!(opts) do
    scopes =
      opts
      |> Keyword.get(:scopes, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if scopes == [], do: Mix.raise("--scopes is required")
    scopes
  end

  defp refuse_staging_apply!(opts) do
    db = Repo.config()[:database]

    if Keyword.get(opts, :apply, false) and db == "swarm_staging" and
         not Keyword.get(opts, :allow_staging, false) do
      Mix.raise(
        "refusing --apply against swarm_staging; set SWARM_DB_NAME to a sandbox clone or pass --allow-staging after taking a rollback snapshot"
      )
    end
  end

  defp warn_staging_apply!(opts) do
    db = Repo.config()[:database]

    # The default refusal protects the reference DB from accidental sandbox
    # commands. `--allow-staging` is the opposite: a deliberate, reversible
    # operator write after a rollback snapshot exists. Make that intent visible
    # in logs so an applied staging run is never mistaken for a dry run.
    if Keyword.get(opts, :apply, false) and db == "swarm_staging" and
         Keyword.get(opts, :allow_staging, false) do
      Mix.shell().info(
        "TOPOLOGY_JOIN_STAGING_APPLY: writing derived topology to swarm_staging; rollback snapshot must already exist"
      )
    end
  end

  defp print_gateway_tree(gateway, scopes) do
    rows = TopologyJoin.gateway_tree(gateway, scopes)
    Mix.shell().info("gateway_tree.gateway=#{gateway} edges=#{length(rows)}")

    Enum.each(rows, fn row ->
      Mix.shell().info(
        "#{row.src} --#{row.relation}--> #{row.dst} " <>
          "edge=#{row.edge_id} seen=#{row.seen_count} reliability=#{Float.round(row.reliability || 0.0, 3)} " <>
          "origins=#{inspect(row.origins)} evidence=#{inspect(row.evidence)}" <>
          cluster_context(row)
      )
    end)
  end

  defp cluster_context(%{cluster_context: []}), do: ""
  defp cluster_context(%{cluster_context: nil}), do: ""

  defp cluster_context(%{cluster_context: contexts}) when is_list(contexts) do
    rendered =
      contexts
      |> Enum.map(fn context ->
        cluster = Map.fetch!(context, :cluster)
        routed = Map.fetch!(context, :routed_members)
        total = Map.fetch!(context, :total_members)

        "cluster=#{cluster} routed_hosts=#{routed}/#{total}"
      end)
      |> Enum.join(",")

    " cluster_context=[#{rendered}]"
  end

  defp cluster_context(%{}), do: ""
end
