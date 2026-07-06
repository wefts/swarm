defmodule Swarm.WorldMap.Coverage do
  @moduledoc """
  The tier-routing gate's coverage layer (workspace ADR-17 §2–3, Fork B — council
  `board/research/tier-gate-blackboard.md`). Turns a query + the pre-built graph
  structure into a **deterministic** `%Descriptor{}`, then a typed `validate/1` that is
  the STRUCTURAL fail-closed gate (Stage 1). The semantic entailment veto (Stage 2) and
  the wire into `Ask` live in `Swarm.WorldMap.Gate`.

  **The fail-closed shape is a property of the types, not a convention** (council
  Correction-adjacent, both families): a servable answer is `%Validated{}`, and the ONLY
  way to mint one is `validate/1` returning `{:ok, _}` — it never returns a `Validated`
  when any blocker is present. `render`/serve paths consume `Validated` only, so a
  descriptor with a stale / non-citable / contradicted / generation-collided / ambiguous
  slot can never be served: it is `{:error, [blocker]}` ⇒ escalate.

  Stage 1 is strict + boring. It proves the structure is present, citable, current and
  unambiguous — NOT that it answers the user's exact question (that is Stage 2's
  entailment job, `Swarm.WorldMap.Gate`). Coverage COUNT is never the signal.

  Intents:
    * `:procedure` — a "how do I X" with exactly ONE clean, generation-collision-free
      procedure variant (from `Swarm.Graph.Procedure`). >1 variant (across origins or
      candidate entities) ⇒ `:ambiguous_variants` ⇒ escalate (the consilium reconciles;
      the council forbade positional merging).
    * `:entity_profile` — a "what is X" with ≥1 corroborated claim group (from
      `Swarm.Graph.Aggregation`). Structural health only here; Stage 2 judges sufficiency.
    * `:unknown` — no clean structure ⇒ escalate.

  Provenance never leaks (residual #1): procedure citations are OPAQUE enumerated source
  labels minted here, never the raw `origin`; entity citations are corroboration COUNTS
  (Aggregation already emits only counts).
  """

  alias Swarm.Graph.Aggregation
  alias Swarm.Graph.Procedure

  @typedoc "What kind of structure, if any, cleanly covers the query."
  @type intent :: :procedure | :entity_profile | :unknown

  @typedoc "Why the structure is insufficient to serve — any blocker ⇒ escalate."
  @type blocker ::
          :empty_scopes
          | :unknown_intent
          | :no_candidate
          | :ambiguous_variants
          | :generation_collision
          | :no_corroboration

  # Query cue for a procedure ask ("how do I X", "steps to Y", "reset Z"). A cue is
  # necessary but NOT sufficient — a clean procedure variant must also exist in structure.
  @procedure_cue ~r/\b(how\s+(do|to|can|would|should)|steps?|procedure|reset|configure|set\s?up|install|enable|disable|troubleshoot|provision|deploy|restart|rotate)\b/i

  defmodule Descriptor do
    @moduledoc "Raw (unvalidated) coverage. Deterministic output of `Coverage.describe/3`."
    @enforce_keys [:query, :intent]
    defstruct query: nil,
              intent: :unknown,
              procedure_name: nil,
              procedure_variants: [],
              entity_groups: [],
              blockers: []

    @type t :: %__MODULE__{
            query: String.t(),
            intent: Swarm.WorldMap.Coverage.intent(),
            procedure_name: String.t() | nil,
            procedure_variants: [map()],
            entity_groups: [map()],
            blockers: [Swarm.WorldMap.Coverage.blocker()]
          }
  end

  defmodule Validated do
    @moduledoc """
    A structurally-sufficient coverage. **Constructible ONLY by `Coverage.validate/1`**
    on a blocker-free descriptor — this is what makes a false-serve unrepresentable.
    `atoms` are the citable evidence units (steps or claim groups); `citations` are
    opaque, leak-free source references.
    """
    @enforce_keys [:query, :intent, :atoms, :citations]
    defstruct [:query, :intent, :atoms, :citations, name: nil]

    @type t :: %__MODULE__{
            query: String.t(),
            intent: :procedure | :entity_profile,
            atoms: [map()],
            citations: [String.t()],
            name: String.t() | nil
          }
  end

  @doc """
  Compute the deterministic coverage `%Descriptor{}` for `query` under `scopes`.

  `opts` (all injectable for testing / to reuse structure Core already built):
    * `:profile` — a `Swarm.Graph.Aggregation.profile()` (default: computed here);
    * `:candidate_keys` — entity node keys to probe for procedures (default `[]`; the
      wire layer supplies the retrieval hits' keys);
    * `:procedure_fun` — `&Procedure.steps/3` (injectable).
  """
  @spec describe(String.t(), [String.t()], keyword()) :: Descriptor.t()
  def describe(query, scopes, opts \\ [])

  def describe(query, [], _opts) when is_binary(query),
    do: %Descriptor{query: query, intent: :unknown, blockers: [:empty_scopes]}

  def describe(query, scopes, opts) when is_binary(query) and is_list(scopes) do
    procedure_fun = Keyword.get(opts, :procedure_fun, &Procedure.steps/3)
    candidate_keys = Keyword.get(opts, :candidate_keys, [])
    profile = Keyword.get(opts, :profile) || Aggregation.entity_profile(query, scopes)

    cue? = Regex.match?(@procedure_cue, query)

    # Pick the BEST-matching procedure ENTITY (candidate_keys are overlap-RANKED, best first),
    # not the union of all — different candidate entities are DIFFERENT procedures, so unioning
    # them would spuriously look "ambiguous". Ambiguity means multiple ORIGINS of the ONE
    # chosen procedure (handled in procedure_descriptor), never multiple distinct procedures.
    chosen = if cue?, do: first_procedure(candidate_keys, scopes, procedure_fun), else: :none

    cond do
      match?({_name, [_ | _]}, chosen) ->
        {name, variants} = chosen
        procedure_descriptor(query, name, variants)

      # A procedure cue with NO clean variant must ESCALATE — it is NOT reclassified as
      # an entity ask (codex review): "how do I reset X" wants the PROCESS; serving
      # entity facts about X would be a category mismatch. Honor the intent split.
      cue? ->
        %Descriptor{query: query, intent: :procedure, blockers: [:no_candidate]}

      profile.groups != [] ->
        entity_descriptor(query, profile)

      true ->
        %Descriptor{query: query, intent: :unknown, blockers: [:unknown_intent]}
    end
  end

  @doc """
  The Stage-1 structural gate. `{:ok, %Validated{}}` ONLY when the descriptor is
  blocker-free and a citable answer can be built; otherwise `{:error, [blocker]}`.
  Fail-closed by construction — the `_` clause escalates anything unexpected.
  """
  @spec validate(Descriptor.t()) :: {:ok, Validated.t()} | {:error, [blocker()]}
  def validate(%Descriptor{blockers: [_ | _] = blockers}), do: {:error, blockers}

  def validate(%Descriptor{intent: :procedure, procedure_variants: [variant], query: q} = d) do
    {:ok,
     %Validated{
       query: q,
       intent: :procedure,
       name: d.procedure_name,
       atoms: variant.steps,
       citations: [variant.citation]
     }}
  end

  def validate(%Descriptor{intent: :entity_profile, entity_groups: [_ | _] = groups, query: q}) do
    {:ok,
     %Validated{
       query: q,
       intent: :entity_profile,
       atoms: groups,
       citations: entity_citations(groups)
     }}
  end

  # Fail-closed default: unknown intent, empty/multi variant, empty groups — escalate.
  def validate(%Descriptor{blockers: blockers}) do
    {:error, if(blockers == [], do: [:unknown_intent], else: blockers)}
  end

  # --- descriptor builders (deterministic) -----------------------------------

  # The variants of the FIRST candidate entity (in ranked order) that has any ordered-step
  # variants — i.e. the best-matching procedure. Distinct later candidates are distinct
  # procedures, not extra variants of this one, so they are not mixed in.
  defp first_procedure([], _scopes, _procedure_fun), do: :none

  defp first_procedure([key | rest], scopes, procedure_fun) do
    case procedure_fun.(key, scopes, []) do
      [] -> first_procedure(rest, scopes, procedure_fun)
      variants -> {key, variants}
    end
  end

  defp procedure_descriptor(query, name, variants) do
    labelled = Enum.map(Enum.with_index(variants, 1), &label_variant/1)
    collision? = Enum.any?(variants, & &1.has_generation_collision?)
    stepless? = Enum.any?(variants, &(&1.steps == []))

    blockers =
      cond do
        collision? -> [:generation_collision]
        length(variants) > 1 -> [:ambiguous_variants]
        stepless? -> [:no_candidate]
        true -> []
      end

    %Descriptor{
      query: query,
      intent: :procedure,
      procedure_name: name,
      procedure_variants: labelled,
      blockers: blockers
    }
  end

  # Opaque, leak-free citation: an enumerated source label, NEVER the raw origin
  # (residual #1). The raw origin is dropped here and does not travel with the answer.
  defp label_variant({variant, idx}) do
    %{
      citation: "source-#{idx}",
      steps: Enum.map(variant.steps, &%{ordinal: &1.ordinal, key: &1.key}),
      has_generation_collision?: variant.has_generation_collision?
    }
  end

  # Keep ONLY citable evidence before minting the descriptor (codex review): filter each
  # group's objects to corroboration ≥ 1 and drop groups left empty. A `%Validated{}` then
  # renders only citable atoms — a zero-corroboration object can never reach a served
  # answer. Empty after filtering ⇒ `:no_corroboration` ⇒ escalate.
  defp entity_descriptor(query, %{groups: groups}) do
    citable =
      groups
      |> Enum.map(fn g -> Map.update!(g, :objects, &Enum.filter(&1, fn o -> citable?(o) end)) end)
      |> Enum.reject(fn g -> g.objects == [] end)

    %Descriptor{
      query: query,
      intent: :entity_profile,
      entity_groups: citable,
      blockers: if(citable == [], do: [:no_corroboration], else: [])
    }
  end

  # An object is citable iff asserted by ≥1 evidential source (corroboration ≥ 1).
  defp citable?(object), do: Map.get(object, :corroboration, 0) >= 1

  # Entity citations are corroboration COUNTS only (Aggregation deliberately never emits
  # a source identity — a count cannot leak which document asserted a claim).
  defp entity_citations(groups) do
    groups
    |> Enum.flat_map(fn %{objects: objects} ->
      Enum.map(objects, &Map.get(&1, :corroboration, 0))
    end)
    |> Enum.filter(&(&1 >= 1))
    |> Enum.map(&"corroboration:#{&1}")
    |> Enum.uniq()
  end
end
