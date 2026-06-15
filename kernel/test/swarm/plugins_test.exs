defmodule Swarm.PluginsTest do
  use Swarm.GraphCase, async: false

  alias Swarm.{Ingest, Plugins}

  @demo """
  defmodule ConnectorDemo do
    @behaviour Swarm.Ports.Connector
    @impl true
    def describe, do: %{name: "connector_demo", kind: :connector, source: "demo"}
    @impl true
    def stream(_opts), do: []
  end
  """

  test "load_connectors compiles and registers a Connector adapter from a dir" do
    dir = Path.join(System.tmp_dir!(), "swarm_plugins_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "connector_demo"))
    File.write!(Path.join([dir, "connector_demo", "connector_demo.ex"]), @demo)

    connectors = Plugins.load_connectors(dir)
    assert Enum.any?(connectors, &(&1.name == "connector_demo"))
  end

  test "absent plugins dir yields no connectors (not an error)" do
    assert Plugins.load_connectors(Path.join(System.tmp_dir!(), "does_not_exist_xyz")) == []
  end

  @tag :integration
  test "the real reference connector (outside repo) ingests files into the graph" do
    assert {:ok, conn} = Swarm.Plugins.Registry.lookup("connector_fs")

    root = Path.join(System.tmp_dir!(), "swarm_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "one.txt"), "hello")
    File.write!(Path.join(root, "two.txt"), "світ")

    conn.module.stream(root: root)
    |> Enum.each(fn event -> assert {:ok, :written} = Ingest.ingest(event) end)

    %{rows: [[files]]} = Repo.query!("SELECT count(*) FROM node WHERE type = 'file'")
    assert files == 2
  end
end
