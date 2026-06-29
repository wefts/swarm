defmodule Swarm.Config do
  @moduledoc """
  Runtime config readers. Config is read at call time from the environment,
  never cached at import — secrets come from env, defaults match local infra.
  """

  @typedoc "Where the Python ML boundary lives and which embedding namespace to stamp."
  @type ml_boundary :: %{address: String.t(), namespace: String.t()}

  @doc "Address and default embedding namespace for the Python ML service."
  @spec ml_boundary() :: ml_boundary()
  def ml_boundary do
    %{
      address: env("SWARM_ML_ADDRESS", "127.0.0.1:50051"),
      namespace: env("SWARM_ML_NAMESPACE", "bge-m3")
    }
  end

  @typedoc """
  ML channel pool (the kernel↔ML transport). `connect_fun` is injectable so the
  pool can be exercised without a live ML service in unit tests.
  """
  @type ml_pool :: %{
          enabled: boolean(),
          size: pos_integer(),
          address: String.t(),
          keepalive_ms: pos_integer(),
          backoff_ms: pos_integer(),
          backoff_max_ms: pos_integer(),
          connect_fun: (String.t(), keyword() -> {:ok, GRPC.Channel.t()} | {:error, term()})
        }

  @doc """
  Long-lived ML channel pool config. Defaults match the 2-replica `ml` service
  (size ≈ replicas × 2); `SWARM_ML_POOL_SIZE` overrides size at deploy time.
  """
  @spec ml_pool() :: ml_pool()
  def ml_pool do
    cfg = Application.get_env(:swarm, :ml_pool, [])

    %{
      enabled: Keyword.get(cfg, :enabled, true),
      size: env_int("SWARM_ML_POOL_SIZE", Keyword.get(cfg, :size, 4)),
      address: ml_boundary().address,
      keepalive_ms: Keyword.get(cfg, :keepalive_ms, 10_000),
      backoff_ms: Keyword.get(cfg, :backoff_ms, 500),
      backoff_max_ms: Keyword.get(cfg, :backoff_max_ms, 5_000),
      connect_fun: Keyword.get(cfg, :connect_fun, &GRPC.Stub.connect/2)
    }
  end

  @typedoc "Consilium fleet: parallel panel models and the synthesizing judge."
  @type consilium :: %{panel: [String.t()], judge: String.t(), token_ceiling: pos_integer()}

  @doc "Consilium panel + judge model roster + per-escalation token ceiling (Domain 4)."
  @spec consilium() :: consilium()
  def consilium do
    cfg = Application.get_env(:swarm, :consilium, [])

    %{
      panel: Keyword.fetch!(cfg, :panel),
      judge: Keyword.fetch!(cfg, :judge),
      token_ceiling: Keyword.get(cfg, :token_ceiling, 32_000)
    }
  end

  @typedoc "Retained-deliberation policy (swarm ADR-15): kill-switch + retention bounds."
  @type deliberation :: %{
          enabled: boolean(),
          retention_ttl_days: pos_integer(),
          max_rows: pos_integer()
        }

  @doc """
  Deliberation retention policy (ADR-15). `enabled: false` is the kill-switch (never
  retain, `ask_ref` always empty); `retention_ttl_days` + `max_rows` bound the store,
  reaped on the ADR-10 trace-GC pass. Tunable per instance without a code change.
  """
  @spec deliberation() :: deliberation()
  def deliberation do
    cfg = Application.get_env(:swarm, :deliberation, [])

    %{
      enabled: Keyword.get(cfg, :enabled, true),
      retention_ttl_days: Keyword.get(cfg, :retention_ttl_days, 30),
      max_rows: Keyword.get(cfg, :max_rows, 10_000)
    }
  end

  @typedoc "ActivityFeed page-size bounds (swarm ADR-15)."
  @type activity_feed :: %{default_limit: pos_integer(), max_limit: pos_integer()}

  @doc """
  ActivityFeed page-size bounds (ADR-15): `default_limit` (used when the request
  asks for 0) and `max_limit` (the hard clamp). Per-poll work is bounded by the
  database stopping the scope-filtered scan at the returned `limit` — there is no
  wire-visible scan budget on purpose (a seq-window budget would let poll count
  leak hidden-event volume; ADR-15 council). The opaque-cursor key lives under the
  same `:activity_feed` env (`:cursor_key`, read by `Activity.Cursor`).
  """
  @spec activity_feed() :: activity_feed()
  def activity_feed do
    cfg = Application.get_env(:swarm, :activity_feed, [])

    %{
      default_limit: Keyword.get(cfg, :default_limit, 50),
      max_limit: Keyword.get(cfg, :max_limit, 100)
    }
  end

  @doc "Hard per-call prompt ceiling at the model boundary (T5, ADR-7); the global backstop."
  @spec max_prompt_tokens() :: pos_integer()
  def max_prompt_tokens do
    Application.get_env(:swarm, :llm, [])
    |> Keyword.get(:max_prompt_tokens, 64_000)
  end

  @doc "Dimensionality of the stored embedding vectors (ADR-6)."
  @spec embedding_dim() :: pos_integer()
  def embedding_dim, do: Keyword.fetch!(Application.get_env(:swarm, :embedding, dim: 768), :dim)

  @doc "Per-day decay constant λ (ADR-3/ADR-9). Tuning inventory (ADR-8)."
  @spec decay_lambda() :: float()
  def decay_lambda, do: Keyword.fetch!(decay(), :lambda)

  @doc "Hill saturation constant S for f(seen_count) (ADR-9). Tuning inventory."
  @spec saturation_s() :: float()
  def saturation_s, do: Keyword.fetch!(decay(), :saturation_s)

  @spec decay() :: keyword()
  defp decay, do: Application.get_env(:swarm, :decay, lambda: 0.01, saturation_s: 2.0)

  @doc """
  Edge-visit budget for a single bounded traversal (ADR-3): beyond it the walk
  returns a best-effort result flagged truncated rather than running unbounded.
  Generous by default so normal traversals never truncate; the safety valve for
  pathological density. Tuning inventory (ADR-8).
  """
  @spec traverse_edge_budget() :: pos_integer()
  def traverse_edge_budget,
    do: Application.get_env(:swarm, :traverse, edge_budget: 100_000)[:edge_budget] || 100_000

  @spec env(String.t(), String.t()) :: String.t()
  defp env(key, default), do: System.get_env(key) || default

  @spec env_int(String.t(), integer()) :: integer()
  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_integer(val)
    end
  end
end
