defmodule Swarm.Plugins do
  @moduledoc """
  Runtime plugin loading (system architecture §13). Adapters live OUTSIDE the
  repo in `SWARM_PLUGINS_DIR` (default sibling hive: `../hive/plugins`). The
  current dev loader compiles trusted Elixir source at startup and registers
  modules implementing a port behaviour — here, `Swarm.Ports.Connector`. This is
  a local-dev shortcut, not the future third-party plugin ABI.

  Loading is fail-soft per file: a broken plugin is logged and skipped, it does
  not crash the kernel (graceful degradation).
  """

  require Logger

  @connector_behaviour Swarm.Ports.Connector

  @typedoc "A loaded connector: its declared name and the module implementing it."
  @type connector :: %{name: String.t(), module: module()}

  @doc """
  Resolved plugins directory. `SWARM_PLUGINS_DIR` if set (the normal path —
  local and Spark differ only by this env); otherwise the sibling hive's
  `../hive/plugins` (the kernel app runs from `<repo>/kernel`, so two levels up
  to the checkout workspace).
  """
  @spec dir() :: String.t()
  def dir, do: System.get_env("SWARM_PLUGINS_DIR") || Path.expand("../../hive/plugins", File.cwd!())

  @doc """
  Compile every `*/*.ex` under `plugins_dir` and return those implementing the
  Connector behaviour. Absent dir → `[]` (nothing to load, not an error).
  """
  @spec load_connectors(String.t()) :: [connector()]
  def load_connectors(plugins_dir \\ dir()) do
    if File.dir?(plugins_dir) do
      plugins_dir
      |> Path.join("*/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&compile_file/1)
      |> Enum.filter(&connector?/1)
      |> Enum.map(&entry/1)
    else
      Logger.info("plugins dir #{plugins_dir} absent; no connectors loaded")
      []
    end
  end

  @spec compile_file(String.t()) :: [module()]
  defp compile_file(path) do
    path |> Code.compile_file() |> Enum.map(fn {module, _bin} -> module end)
  rescue
    error ->
      Logger.error("plugin compile failed for #{path}: #{Exception.message(error)}")
      []
  end

  @spec connector?(module()) :: boolean()
  defp connector?(module) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    @connector_behaviour in behaviours
  end

  @spec entry(module()) :: connector()
  defp entry(module) do
    %{name: Map.fetch!(module.describe(), :name), module: module}
  end
end
