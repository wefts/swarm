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
  alias Swarm.WorldMap.Domain

  @typedoc "What kind of structure, if any, cleanly covers the query."
  @type intent :: :procedure | :entity_profile | :neighborhood | :unknown

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
  @procedure_cue ~r/(?:\b(how\s+(do|to|can|would|should)|steps?|procedure|reset|configure|set\s?up|install|enable|disable|troubleshoot|provision|deploy|restart|rotate)\b|(?<![\p{L}\p{N}_])((як|як\s+.+\s)(налаштувати|сконфігурувати|конфігурувати|встановити|інсталювати|підключити|увімкнути|вимкнути|скинути|перезапустити|розгорнути|задеплоїти|вирішити|полагодити|діагностувати)|налаштувати|сконфігурувати|конфігурувати|встановити|інсталювати|підключити|увімкнути|вимкнути|скинути|перезапустити|розгорнути|задеплоїти|вирішити|полагодити|діагностувати|інструкці[яї]|кроки)(?![\p{L}\p{N}_]))/iu

  # The neighborhood-domain cues (network / who / …) live in the serve-domain CONTRACT
  # (`Swarm.WorldMap.Domain`) — one source per domain, so a new domain can't drift. Checked AFTER the
  # procedure branch, so a how-to about network gear ("configure the firewall") stays a procedure ask.

  defmodule Descriptor do
    @moduledoc """
    Raw (unvalidated) coverage. Deterministic output of `Coverage.describe/3`. A `:neighborhood`
    descriptor (network / who / …) carries the immutable matched `domain` key (E2b council #2) — the
    generic validate/render/entail path refetches that domain's invariants BY KEY, never loosely.
    """
    @enforce_keys [:query, :intent]
    defstruct query: nil,
              intent: :unknown,
              domain: nil,
              procedure_name: nil,
              procedure_variants: [],
              entity_groups: [],
              neighborhood_subject: nil,
              # The RAW resolved graph key (e.g. "who:service:keycloak") behind
              # `neighborhood_subject`'s human-readable label (e.g. "keycloak", or a
              # person's `cn` — `WhoMap.display_subject/1` is NOT invertible). Chat-thread
              # epic 2: this, not the display label, is what a NEXT turn's active_keys
              # must echo back — `dom.neighborhood_fun` only resolves real graph keys.
              neighborhood_key: nil,
              neighborhood_facts: [],
              blockers: []

    @type t :: %__MODULE__{
            query: String.t(),
            intent: Swarm.WorldMap.Coverage.intent(),
            domain: atom() | nil,
            procedure_name: String.t() | nil,
            procedure_variants: [map()],
            entity_groups: [map()],
            neighborhood_subject: String.t() | nil,
            neighborhood_key: String.t() | nil,
            neighborhood_facts: [map()],
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
    defstruct [:query, :intent, :atoms, :citations, name: nil, key: nil, domain: nil]

    @type t :: %__MODULE__{
            query: String.t(),
            intent: :procedure | :entity_profile | :neighborhood,
            atoms: [map()],
            citations: [String.t()],
            name: String.t() | nil,
            # The raw graph key behind `name`'s display label — see `Descriptor.neighborhood_key`.
            # Equal to `name` for :procedure (no display transform there); nil for :entity_profile.
            key: String.t() | nil,
            domain: atom() | nil
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
    # The entity_profile serve path is OFF by default: live validation (2026-07-06) showed it
    # FALSE-SERVES — aggregation matches loosely-related claims to a "what is X"/"who owns X"
    # query and serves the wrong facts. Only the (validated-safe) PROCEDURE path serves until
    # the entity path is calibrated (its own go/no-go). `entity_serve: true` opts back in.
    entity_serve = Keyword.get(opts, :entity_serve, false)

    semantic_route = Keyword.get(opts, :semantic_route, :none)
    cue? = Regex.match?(@procedure_cue, query) or semantic_route == :procedure

    # Pick the BEST-matching procedure ENTITY (candidate_keys are overlap-RANKED, best first),
    # not the union of all — different candidate entities are DIFFERENT procedures, so unioning
    # them would spuriously look "ambiguous". Ambiguity means multiple ORIGINS of the ONE
    # chosen procedure (handled in procedure_descriptor), never multiple distinct procedures.
    chosen = if cue?, do: first_procedure(candidate_keys, scopes, procedure_fun), else: :none

    # The FIRST neighborhood domain (network / who / …) whose serve flag is on AND cue matches, in
    # the registry's precedence order (`Domain.neighborhood_domains/0` — who before network). Each
    # domain is OFF by default until calibrated (false-serve ~0); its serve flag / candidate keys /
    # neighborhood fn / corroboration floor stay injectable as flat `<key>_serve/_keys/_fun/
    # _min_corroboration` opts (defaults from the registry). `nil` ⇒ no neighborhood domain covers it.
    neighborhood = active_neighborhood(query, opts)

    cond do
      match?({_name, [_ | _]}, chosen) ->
        {name, variants} = chosen
        procedure_descriptor(query, name, variants)

      # A procedure cue with NO clean variant must ESCALATE — it is NOT reclassified as
      # an entity ask (codex review): "how do I reset X" wants the PROCESS; serving
      # entity facts about X would be a category mismatch. Honor the intent split. Checked
      # BEFORE any neighborhood domain (a how-to about gear stays a procedure ask).
      cue? ->
        %Descriptor{query: query, intent: :procedure, blockers: [:no_candidate]}

      neighborhood != nil ->
        neighborhood_descriptor(query, neighborhood, scopes, opts)

      entity_serve and profile.groups != [] ->
        entity_descriptor(query, profile)

      true ->
        %Descriptor{query: query, intent: :unknown, blockers: [:unknown_intent]}
    end
  end

  # The first registered neighborhood domain whose serve flag is on AND whose cue matches, in the
  # registry's precedence ORDER (who before network — E2b council #1, reproduces the pre-E2b branch
  # order exactly). `nil` ⇒ no neighborhood domain covers the query.
  @spec active_neighborhood(String.t(), keyword()) :: Domain.t() | nil
  defp active_neighborhood(query, opts) do
    semantic_route = Keyword.get(opts, :semantic_route, :none)

    Enum.find(Domain.neighborhood_domains(), fn dom ->
      Keyword.get(opts, dom.serve_opt, false) and
        (Regex.match?(dom.cue, query) or semantic_route == {:neighborhood, dom.key})
    end)
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
       key: d.procedure_name,
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

  def validate(
        %Descriptor{intent: :neighborhood, neighborhood_facts: [_ | _] = facts, query: q} = d
      ) do
    {:ok,
     %Validated{
       query: q,
       intent: :neighborhood,
       domain: d.domain,
       name: d.neighborhood_subject,
       key: d.neighborhood_key,
       atoms: facts,
       citations: facts |> Enum.map(&"corroboration:#{&1.corroboration}") |> Enum.uniq()
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

  # The GENERIC neighborhood descriptor (network / who / …; E2b collapse). Resolves the FIRST
  # (best-ranked) candidate whose neighborhood is non-empty — facts ≥ the domain's min_corroboration
  # distinct origins/lineage (2 = multi-source-confirmed topology; 1 = the authoritative directory) —
  # and serves those facts, carrying the immutable matched `domain` key (council #2). This
  # corroboration floor is the fail-closed safety choice (the entity_profile path false-served on
  # single, loosely-matched claims): uncorroborated evidence escalates to the consilium.
  # `:no_candidate` (no subject resolves) / `:no_corroboration` (subject found, no floor-meeting
  # facts) ⇒ escalate. The subject label comes from the domain's `subject_fun` (never the raw key).
  defp neighborhood_descriptor(query, %Domain{} = dom, scopes, opts) do
    keys = Keyword.get(opts, :"#{dom.key}_keys", [])
    fun = Keyword.get(opts, :"#{dom.key}_fun", dom.neighborhood_fun)
    min_corr = Keyword.get(opts, :"#{dom.key}_min_corroboration", dom.min_corroboration)

    relation_opts = neighborhood_relation_opts(query, dom)

    case first_neighborhood(keys, scopes, fun, min_corr, dom.subject_fun, relation_opts) do
      {subject, key, facts} ->
        %Descriptor{
          query: query,
          intent: :neighborhood,
          domain: dom.key,
          neighborhood_subject: subject,
          neighborhood_key: key,
          neighborhood_facts: facts
        }

      :none when keys == [] ->
        %Descriptor{
          query: query,
          intent: :neighborhood,
          domain: dom.key,
          blockers: [:no_candidate]
        }

      :none ->
        %Descriptor{
          query: query,
          intent: :neighborhood,
          domain: dom.key,
          blockers: [:no_corroboration]
        }
    end
  end

  # First candidate (ranked) whose neighborhood (facts ≥ `min_corr` distinct origins/lineage) is
  # non-empty; its subject label is the domain's `subject_fun` applied to the resolved key — the
  # raw key itself is ALSO returned (chat-thread epic 2: `subject_fun` is a display transform, not
  # invertible — a served answer's active_keys must echo the raw key, never the display label).
  defp first_neighborhood([], _scopes, _fun, _min_corr, _subject_fun, _relation_opts), do: :none

  defp first_neighborhood([key | rest], scopes, fun, min_corr, subject_fun, relation_opts) do
    case fun.(key, scopes, [min_corroboration: min_corr] ++ relation_opts) do
      [] -> first_neighborhood(rest, scopes, fun, min_corr, subject_fun, relation_opts)
      facts -> {subject_fun.(key), key, facts}
    end
  end

  defp neighborhood_relation_opts(query, %Domain{key: :network}) do
    q = String.downcase(query)

    cond do
      Regex.match?(~r/\b(private|internal|lan)\b|приватн|внутрішн/iu, q) ->
        [relations: ["has_private_address"]]

      Regex.match?(~r/\b(public|outbound|egress|external)\b|публічн|зовнішн/iu, q) ->
        [relations: ["has_public_address", "has_outbound_ip_address"]]

      Regex.match?(~r/\bwhich\s+tunnels?\b.*\bterminate|тунел[\p{L}]*.*термін/iu, q) ->
        [relations: ["terminates_for"]]

      Regex.match?(~r/\bwhich\s+hosts?\b.*\broute|хост[\p{L}]*.*маршрут/iu, q) ->
        [relations: ["routes_for"]]

      Regex.match?(~r/\b(ip|ips|address|addresses)\b|(ip|айпі)[-\s]?адрес/iu, q) ->
        [relations: ["has_address"]]

      true ->
        []
    end
  end

  defp neighborhood_relation_opts(_query, _dom), do: []

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
