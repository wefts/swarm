defmodule Swarm.Ports.Skill do
  @moduledoc """
  Skill port (Domain 11 / T9): task-specific behavior, register, and persona that
  a channel attaches around the kernel's structured facts. A skill chooses *how*
  to phrase — tone, verbosity, language, the rotating off-topic deflection copy,
  context-dependent register (DM dry/sharp vs public warm/refined) — but it
  **never decides the facts**. The kernel emits `status`/`citations`/`confidence`
  (the single voice, ADR-6); a skill skins them.

  Behaviour only — concrete skills are adapters outside the kernel (in `hive`),
  so persona/register/cost-copy is **never** kernel code (presentation-determinism
  standard; T9). The kernel guarantees the cheap path (off-topic → tier0, no
  escalation); a skill supplies the words.
  """

  @typedoc "Rendering context a channel supplies (e.g. surface: :dm | :public, locale)."
  @type context :: map()

  @typedoc "The kernel's structured answer (Core.answer); a skill phrases around it."
  @type answer :: map()

  @doc "Render the answer for this context — register/persona/language. Facts unchanged."
  @callback render(answer(), context()) :: String.t()

  @doc """
  A canned, rotating deflection + steer-back for an off-mission request, chosen
  for the context (public: warm/refined; DM: dry). Zero-LLM by construction.
  """
  @callback deflection(context()) :: String.t()

  @doc "Report skill identity and the contexts/intents it handles."
  @callback describe() :: map()

  @optional_callbacks deflection: 1
end
