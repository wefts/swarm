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
  def dir,
    do: System.get_env("SWARM_PLUGINS_DIR") || Path.expand("../../hive/plugins", File.cwd!())

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
      |> compile_all()
      |> Enum.filter(&connector?/1)
      |> Enum.map(&entry/1)
    else
      Logger.info("plugins dir #{plugins_dir} absent; no connectors loaded")
      []
    end
  end

  # ALL files in one compilation unit, not one `Code.compile_file/1` per file in wildcard
  # order. A plugin is normally several modules -- an observer, its transports, its
  # connector -- and they reference each other. Compiled one at a time alphabetically,
  # `k8s_client_kubectl.ex` reaches for a behaviour that `k8s_observer.ex` has not defined
  # yet: every build emitted "@behaviour Hive.K8s.Observer.Client does not exist" and
  # "Hive.Posix.Observer.classes/0 is undefined". The warnings were false -- the modules do
  # exist -- but a plugin whose load order happened to matter would have failed for real.
  #
  # `Kernel.ParallelCompiler.compile/1` resolves the dependency graph itself, so order
  # stops being something a plugin author has to think about. A failure still degrades to
  # a logged error and an empty list: one bad plugin must not take the kernel down.
  @spec compile_all([String.t()]) :: [module()]
  defp compile_all([]), do: []

  defp compile_all(paths) do
    case Kernel.ParallelCompiler.compile(paths) do
      {:ok, modules, _warnings} ->
        modules

      {:error, errors, _warnings} ->
        Logger.error("plugin compile failed: #{inspect(errors)}")
        []
    end
  rescue
    error ->
      Logger.error("plugin compile raised: #{Exception.message(error)}")
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
