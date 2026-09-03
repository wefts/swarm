defmodule Swarm.WorldMap.Gate.EntityCalibrationTest do
  @moduledoc """
  The :entity_profile serve-path calibration harness (H1). Verifies the metric computation with an
  injected entail (no real model). `false_serve_rate` is the go/no-go gate.
  """
  use ExUnit.Case, async: true

  alias Swarm.WorldMap.Gate.EntityCalibration
  alias Swarm.WorldMap.Gate

  defp collect_systems(0, acc), do: Enum.reverse(acc)

  defp collect_systems(n, acc) do
    receive do
      {:generation_call, system} -> collect_systems(n - 1, [system | acc])
    after
      100 -> flunk("expected #{n} more generation call(s)")
    end
  end

  test "an entail that ALWAYS serves exposes false serves" do
    r = EntityCalibration.score(entail_fun: fn _q, _g -> true end)

    assert r.false_serve_rate == 1.0
    assert r.serve_recall == 1.0
    assert length(r.false_serves) == Enum.count(EntityCalibration.labeled(), &(&1.serve == false))
    assert r.missed_serves == []
  end

  test "an entail that ALWAYS vetoes misses serves" do
    r = EntityCalibration.score(entail_fun: fn _q, _g -> false end)

    assert r.false_serve_rate == 0.0
    assert r.serve_recall == 0.0
    assert r.false_serves == []
    assert length(r.missed_serves) == Enum.count(EntityCalibration.labeled(), & &1.serve)
  end

  test "the labelled set is weighted toward should-VETO near-misses" do
    labels = EntityCalibration.labeled()

    assert Enum.count(labels, &(&1.serve == false)) > Enum.count(labels, & &1.serve)
    assert Enum.count(labels, & &1.serve) >= 3
  end

  test "the labelled set covers multilingual broad-profile recall and strict IP vetoes" do
    by_id = Map.new(EntityCalibration.labeled(), &{&1.id, &1})

    assert by_id["serve-uk-profile-definition"].serve
    assert by_id["serve-uk-profile-definition"].query == "Розкажи про Drupal"

    assert by_id["serve-uk-profile-service"].serve
    assert by_id["serve-uk-profile-service"].query == "Розкажи про Helios AI Program"

    assert by_id["serve-uk-known-about-profile"].serve
    assert by_id["serve-uk-known-about-profile"].query == "Що відомо про Nimbus gateway"

    refute by_id["veto-broad-profile-wrong-entity"].serve
    refute by_id["veto-specific-ip-from-broad-profile"].serve
  end

  test "default calibration entail uses the entity-profile system prompt" do
    parent = self()

    generation_fun = fn _model, _prompt, opts ->
      send(parent, {:generation_call, Keyword.fetch!(opts, :system)})
      {:ok, ~s({"sufficient": false})}
    end

    r = EntityCalibration.score(generation_fun: generation_fun)

    assert r.n == length(EntityCalibration.labeled())

    assert r.n
           |> collect_systems([])
           |> Enum.all?(&(&1 == Gate.entity_entail_system()))
  end

  test "calibration preserves an injected system prompt" do
    parent = self()
    custom_system = "CUSTOM ENTITY CALIBRATION SYSTEM"

    generation_fun = fn _model, _prompt, opts ->
      send(parent, {:generation_call, Keyword.fetch!(opts, :system)})
      {:ok, ~s({"sufficient": true})}
    end

    r = EntityCalibration.score(system: custom_system, generation_fun: generation_fun)

    assert r.n == length(EntityCalibration.labeled())

    assert r.n
           |> collect_systems([])
           |> Enum.all?(&(&1 == custom_system))
  end

  test "an injected entail_fun bypasses generation entirely" do
    r =
      EntityCalibration.score(
        entail_fun: fn _q, _g -> true end,
        generation_fun: fn _model, _prompt, _opts -> raise "must not call generation" end
      )

    assert r.false_serve_rate == 1.0
    assert r.serve_recall == 1.0
  end
end
