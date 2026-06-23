defmodule Swarm.Release do
  @moduledoc """
  Release tasks for the packaged kernel (the prod Docker image).

  A `mix release` has no Mix and no `mix ecto.migrate`, so schema migration runs
  through the release boot script:

      bin/swarm eval "Swarm.Release.migrate()"

  The migrations ship inside the release (`priv/repo/migrations`). `migrate/0`
  loads the app's config (without starting the supervision tree), then starts
  each repo just long enough to run pending migrations — the standard Ecto
  release pattern. The orchestrator (Hive compose) runs this as a one-shot step
  before the kernel service starts.
  """
  @app :swarm

  @doc "Run all pending `:up` migrations for every configured repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Roll a single repo back down to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.load(@app)
end
