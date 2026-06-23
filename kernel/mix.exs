defmodule Swarm.MixProject do
  use Mix.Project

  def project do
    [
      app: :swarm,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]]
    ]
  end

  # Production release (Task: dockerization). `runtime.exs` is fully env-driven,
  # so one assembled release runs in every environment — only the env differs.
  # `:tar` also emits a tarball, a self-contained artifact for an offline machine
  # (the "move somewhere with no internet and it still runs" requirement).
  defp releases do
    [
      swarm: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end

  # The kernel is supervised: the application starts the supervision tree.
  def application do
    [
      extra_applications: [:logger],
      mod: {Swarm.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Storage: Postgres + pgvector (decided by the storage spike).
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:pgvector, "~> 0.3"},
      # Elixir<->Python boundary and the typed ports.
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.13"},
      # Codegen for the .proto contracts (mix protobuf.generate).
      {:protobuf_generate, "~> 0.1", only: [:dev, :test], runtime: false},
      # Quality gates.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
