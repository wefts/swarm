defmodule Swarm.ML.Prewarm do
  @moduledoc """
  One-shot warmup for the deployed ML fleet.

  The Hive deployment pins models with keep_alive=-1 to avoid cold-load tax, so
  warming them at kernel start turns the first browser ask after a deploy into the
  same path as steady-state traffic. This is deliberately best-effort: a warmup
  miss is logged and the normal ask path still fails closed through its own
  breakers.
  """

  require Logger

  alias Swarm.ML.{Embeddings, Generation}

  @default_timeout_ms 120_000
  @retry_sleep_ms 250

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, configured_timeout_ms())

    Logger.info(
      "ml prewarm: warming embedder and #{length(generation_models())} generation model(s)"
    )

    warm("embedder #{Swarm.Config.ml_boundary().namespace}", timeout_ms, fn ->
      Embeddings.embed(["swarm prewarm"])
    end)

    Enum.each(generation_models(), fn model ->
      warm("generation #{model}", timeout_ms, fn ->
        Generation.generate(model, ~s({"ready":true}),
          system: "Return exactly one compact JSON object.",
          json: true
        )
      end)
    end)

    :ignore
  end

  defp generation_models do
    consilium = Swarm.Config.consilium()
    tier_gate = Application.get_env(:swarm, :tier_gate, [])

    ([Keyword.get(tier_gate, :entail_model), consilium.judge] ++ consilium.panel)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp configured_timeout_ms do
    Application.get_env(:swarm, :ml_prewarm, [])
    |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end

  defp warm(label, timeout_ms, fun) do
    started = System.monotonic_time(:millisecond)

    case run_until_ready(fun, started + timeout_ms) do
      {:ok, {:ok, _}} ->
        Logger.info("ml prewarm: #{label} ready in #{elapsed_ms(started)}ms")

      {:ok, {:error, reason}} ->
        Logger.warning("ml prewarm: #{label} failed (#{inspect(reason)})")

      :timeout ->
        Logger.warning("ml prewarm: #{label} timed out after #{timeout_ms}ms")
    end
  end

  defp run_until_ready(fun, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      :timeout
    else
      task = Task.async(fun)

      case Task.yield(task, remaining_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:error, {:ml_unavailable, :no_healthy_channel}}} ->
          Process.sleep(@retry_sleep_ms)
          run_until_ready(fun, deadline_ms)

        result ->
          result
      end
    end
  end

  defp elapsed_ms(started) do
    System.monotonic_time(:millisecond) - started
  end
end
