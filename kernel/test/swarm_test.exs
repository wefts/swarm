defmodule SwarmTest do
  use ExUnit.Case, async: true

  describe "health/0" do
    test "reports :ok when Postgres answers" do
      assert {:ok, %{db: :ok}} = Swarm.health()
    end
  end
end
