defmodule Swarm do
  @moduledoc """
  Swarm kernel entry point.

  The kernel owns coordination, graph orchestration, the gate, and the boundary
  to the Python ML pillar — everything that grows over time is an adapter behind
  a port (see `Swarm.Ports.*`). This module exposes only a trivial liveness
  check for now.
  """

  alias Swarm.Repo

  @typedoc "Health report: each subsystem is `:ok` or a typed error."
  @type report :: %{db: :ok}

  @doc """
  Liveness check: pings Postgres through the `Repo`.

  Fail-loud — returns `{:ok, report}` only when the DB answers as expected, and a
  typed `{:error, reason}` otherwise. A caller must branch; there is no
  success-shaped error.
  """
  @spec health() :: {:ok, report()} | {:error, term()}
  def health do
    case ping_db() do
      :ok -> {:ok, %{db: :ok}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ping_db() :: :ok | {:error, term()}
  defp ping_db do
    case Repo.query("SELECT 1") do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, other} -> {:error, {:unexpected_db_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
