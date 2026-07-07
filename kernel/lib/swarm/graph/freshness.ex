defmodule Swarm.Graph.Freshness do
  @moduledoc """
  Freshness / time-decay for the serve path (world-map master plan S2; decorrelated review
  2026-07-07, codex + gemini). Three ORTHOGONAL signals govern a served fact — reliability (source
  tier), corroboration (distinct lineage, S1), and FRESHNESS (this module). They are NOT blended
  into one vote: freshness is a separate gate + a factor on the conflict-ranking reliability.

  - **effective_reliability = base × decay(age, class)** ranks conflicting facts, so a STALE
    high-tier fact loses to a FRESH lower-tier one.
  - **`fresh?/3`** is the serve GATE: a fact whose decay factor falls below `@fresh_floor` is too
    stale to serve confidently → the caller escalates (fail-closed). Below-cutoff never asserts the
    fact is FALSE/decommissioned (no refutation signal) — it stays as historical evidence, just not
    served (codex).

  **Per-relation via CLASSES, not 40 knobs.** Each relation maps to a freshness class with a
  half-life; operational state decays in days, topology/identity in months/years, so stable facts
  don't over-escalate (codex). λ = ln(2)/half_life_days ⇒ decay(half_life) = 0.5.

  **Age is measured against the graph's FRESHNESS FRONTIER (the newest `last_seen`), not wall-clock**
  — so if ingestion (the nightly crons) STALLS, nothing gets newer, ages stop growing, and the whole
  graph does not decay-then-escalate at once (gemini's escalation-DDoS trap → this self-freezes).
  """

  @type class :: :operational | :configuration | :structural | :identity

  # half-life (days) per freshness class → λ = ln(2)/half_life. Tuning-inventory candidates (ADR-8).
  @half_life_days %{operational: 3.0, configuration: 30.0, structural: 180.0, identity: 3650.0}

  # relation → class. Default (unknown relation) = :configuration (safe middle). Topology/physical
  # + org structure are slow; addresses/hosting/deps medium; typing/aliases near-immutable.
  @relation_class %{
    "is_a" => :identity,
    "alias_of" => :identity,
    "has_hostname" => :identity,
    "contains" => :structural,
    "connects_site" => :structural,
    "terminates_at" => :structural,
    "routes_via" => :structural,
    "egresses_via" => :structural,
    "protected_by" => :structural,
    "carries" => :structural,
    "located_at" => :structural,
    "located_in" => :structural,
    "part_of" => :structural,
    "has_address" => :configuration,
    "hosted_on" => :configuration,
    "uses" => :configuration,
    "requires" => :configuration,
    "provides" => :configuration,
    # org-membership (E1 who-is-who): changes on an employee move/reorg — 30d BACKSTOP so a stale
    # edge decays out of serve within weeks if the daily directory reconcile ever stops (the primary
    # staleness defense is full-state reconciliation, which purges departed/moved people at once;
    # decorrelated review 2026-07-07 flagged 180d as too slow a backstop for org facts).
    "managed_by" => :configuration,
    "works_in" => :configuration,
    "member_of" => :configuration,
    "has_title" => :configuration,
    # employment category + clustered role family: stable typing-like facts (change on a
    # role/contract change) — structural backstop; reconciliation is the primary staleness defense.
    "has_employment" => :structural,
    "has_role_family" => :structural
  }

  # serve floor: a fact decayed below this factor is too stale to serve (→ escalate). 0.5 = one
  # half-life of its class (operational ~3d, structural ~180d, identity ~10y).
  @fresh_floor 0.5

  @doc "The freshness class for a relation (default :configuration)."
  @spec class(String.t()) :: class()
  def class(relation), do: Map.get(@relation_class, relation, :configuration)

  @doc "Decay factor exp(-λ_class · age_days) ∈ (0,1]. `age_seconds` clamped ≥ 0 (frontier ≥ last_seen)."
  @spec decay_factor(number(), String.t()) :: float()
  def decay_factor(age_seconds, relation) do
    age = max(age_seconds, 0) / 86_400.0
    lambda = :math.log(2) / Map.fetch!(@half_life_days, class(relation))
    :math.exp(-lambda * age)
  end

  @doc "effective_reliability = base × decay(age, class) — for conflict ranking (stale loses)."
  @spec effective_reliability(float(), number(), String.t()) :: float()
  def effective_reliability(base, age_seconds, relation) do
    base * decay_factor(age_seconds, relation)
  end

  @doc """
  Serve gate: is this fact fresh enough to serve? True iff its class decay factor ≥ `@fresh_floor`.
  `age_seconds` is measured against the graph's freshness frontier by the caller (self-freezing).
  """
  @spec fresh?(number(), String.t()) :: boolean()
  def fresh?(age_seconds, relation), do: decay_factor(age_seconds, relation) >= @fresh_floor

  @doc "The serve floor (decay factor below which a fact is too stale to serve)."
  @spec fresh_floor() :: float()
  def fresh_floor, do: @fresh_floor
end
