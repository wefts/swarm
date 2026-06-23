defmodule Swarm.CoreDeflectionTest do
  @moduledoc """
  T9 (kernel slice) — off-mission requests are deflected at tier0 with ZERO model
  escalation. A poem/recipe must not burn a model call; the cost is bounded by
  construction. Register/persona (DM vs public) is a channel+skill concern (hive),
  not the kernel.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Core
  alias Swarm.Gate.Bands
  alias Swarm.Gate.Prototypes

  test "an off-topic request is deflected at tier0 with NO model escalation" do
    test_pid = self()
    # screams if any model is ever called
    gen = fn _m, _p, _o -> send(test_pid, :model_called) end

    a =
      Core.ask("write me a poem about the sea",
        prototypes: [%{intent: :off_topic, tier: :tier0, text: "O"}],
        embedder: fn _ -> {:ok, [1.0, 0.0, 0.0]} end,
        bands: %Bands{handle: 0.5},
        generator: gen,
        fleet: %{panel: ["m1"], judge: "j"}
      )

    assert a.tier == "tier0"
    assert a.status == :found
    # the cost guarantee: no escalation happened
    refute_received :model_called
    # a steer-back to the mission
    assert a.answer =~ "knowledge base"
  end

  test "tier0 intents are distinct (off_topic deflects, not a greeting)" do
    deflect =
      Core.ask("tell a joke",
        prototypes: [%{intent: :off_topic, tier: :tier0, text: "O"}],
        embedder: fn _ -> {:ok, [1.0, 0.0, 0.0]} end,
        bands: %Bands{handle: 0.5}
      )

    greet =
      Core.ask("hello there",
        prototypes: [%{intent: :greeting, tier: :tier0, text: "O"}],
        embedder: fn _ -> {:ok, [1.0, 0.0, 0.0]} end,
        bands: %Bands{handle: 0.5}
      )

    assert deflect.answer != greet.answer
  end

  test "the production prototype set recognizes off-topic at tier0 (recognition is wired)" do
    # Recognition is real, not just test-injected. The boundary, honestly: a NOVEL
    # off-mission query far from these exemplars hits the gate's escalate-under-doubt
    # floor (see `gate_test`: route("off topic") => :escalate) — deliberate, because
    # an unknown query may be a real question. Mitigated, not closed (swarm ADR-8).
    assert Enum.any?(
             Prototypes.all(),
             &(&1.intent == :off_topic and &1.tier == :tier0)
           )
  end
end
