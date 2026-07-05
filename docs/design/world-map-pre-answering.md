---
status: in-build (substrate + tier-gate BUILT 2026-07-05, OFF by default; NEXT = qa-gold curation + measurement + go/no-go council to enable)
adr: workspace ADR-17 (Accepted 2026-07-04)
owns: swarm kernel — procedure representation, aggregation view, tier-routing gate; hive — glpi-agent oracle connector (later phase)
supersedes: nothing (composes ADR-13 evidential origin + the shipped STEP-2 aggregation; overrides the charter's glpi-first bootstrap lean)
---

# World-map pre-answering (design spec)

Implements workspace **ADR-17**. Answer most asks from a continuously-maintained world-map
(entities, relations, **procedures**) via cheap retrieval + aggregation over pre-built
structure; escalate to the consilium **only** when a routing gate judges the structure
insufficient. Composes the already-shipped cognitive substrate — this spec adds a
representation, an aggregation view, a **gate**, and (later) a bootstrap source. Council
record: `board/research/world-map-blackboard.md`. Epic: `board/doing/world-map-pre-answering-epic.md`.

## 0. What already exists (compose, do not rebuild)

- **enrichment worker** (reward-gated, nightly bounded) — extracts S-P-O claims as
  `evidence_kind=claim` edges with `origin`+reliability.
- **entity-resolution** (ADR-13 §3.2) + carded `concept-synonymy-resolution` — keeps the
  concept vocabulary coherent (a **prerequisite** so any surface form reaches one node).
- **STEP-2 aggregation** (`Swarm.Graph.Aggregation`) — answers "what is X" over grouped
  claim-edges, corroboration-ranked, scope-enforced, **no reification**.
- **evidential origin + content-watermark** (ADR-13) — provenance + staleness signal.
- **the fail-closed judge** (`supported` flag) and the `Ask` tier structure (tier0 /
  tools / escalate).

## 1. Representation — procedures as ordered claim-edges (Fork A)

A **procedure is not a new node type.** It is an existing `entity` node (e.g. the concept
"password reset") with **ordered claim-edges** hanging off it:

- `has_step` — edge to a step's content node; carries an integer **`step_ordinal`** for
  ordering. (Reconciled 2026-07-05: the `edge` table has NO generic property/JSONB map —
  the spec's "property map" was wrong. The ordinal is a dedicated **nullable
  `step_ordinal smallint` column on `edge`** (NULL for every non-step edge) — a versioned
  schema bump, minimal, no join on the read path, reversible. A JSONB `props` was the
  more general alternative but YAGNI on the hot edge table; generalize if a second
  consumer appears.)
- `requires_tool` — edge to the tool/system a step uses.
- `applies_to` — edge to the situation/scope the procedure covers.

Every step edge keeps `origin` + `reliability` + reversibility exactly like any claim edge
(ADR-13). **Reification stays closed:** a step is an edge asserting "this source says step
N is X", never a first-class truth-node.

**Load-bearing constraint (the council's sharpest catch):** a procedure may be described by
more than one source. The aggregation **groups `has_step` edges by `origin` FIRST, then
orders by `step_ordinal` within each origin** — never interleaves indices across sources
(two docs' "step 1" would otherwise fuse into a broken chain). When multiple origins
describe the same procedure, present them as corroborating variants (reuse the STEP-2
corroboration ranking), do not merge step-lists positionally.

**Fallback (deferred, not built up front):** if the read-time view cannot cleanly tell a
procedure-bearing entity from a plain one, introduce a `procedure` node **kind** via a
versioned `Contract.types/0` bump — but only with evidence from the spike that aggregation
alone is insufficient.

## 2. The aggregation view — `procedure(entity)` (Fork A + D)

A read-time projection (sibling of STEP-2 `Aggregation`), NOT stored:

1. resolve the query's entity (via synonymy-coherent nodes);
2. gather its `has_step`/`requires_tool`/`applies_to` edges, **scope-enforced** (edge +
   both endpoints, exactly as the corroboration query);
3. group by `origin`, order steps by `step_ordinal` within origin;
4. attach each step's citation (source node) — every emitted step is **citable**;
5. compute a **coverage descriptor** for the gate (§3): which intent slots are filled, by
   how many independent origins, at what reliability, whether any dependency watermark is
   stale, whether contradictions are unresolved.

**Coverage descriptor shape (tier-gate council 2026-07-05, `board/research/tier-gate-blackboard.md`):**
a deterministic `%CoverageDescriptor{}` — `intent :procedure|:entity_profile|:unknown`;
`required_slots` each `%Slot{key, status: :filled|:missing|:ambiguous|:contradicted|:stale,
evidence_count, current_citable_count}`; per-variant procedure flags (`variant_id` **opaque,
NOT the raw origin**, `label`, `step_count`, `contiguous_ordinals?`, `all_steps_current?`,
`all_steps_citable?`, **`has_generation_collision?`**, `has_refuted_steps?`,
`has_internal_contradiction?`, `citations`); entity filled/missing/contradicted/stale
predicate sets; watermark summary; and an explicit **`blockers` list**. **Slot sufficiency is
structural** — a light intent tag may assist classification but never overrides "structure has
no clean candidate ⇒ escalate." The descriptor adds explicit slots for **applicability /
prerequisites / terminal success condition** (codex's sink-risk: a "missing precondition"
false-serve must be a *structural* miss, not only a Stage-2 catch).

**Freshness (Fork D):** nothing is cached. The view runs on every read over **current**
edges. A step whose source node's `content_watermark` has moved since the edge was written
is marked **stale** and excluded from the "supported" set (the gate then likely escalates).
**Ghost-procedure hazard — CLOSED 2026-07-05** (council `board/research/gc-ghost-purge-blackboard.md`):
when a source node is deleted or merged, its derived edges are **purged** (not re-pointed —
extraction is a re-derivable derivative of source text; re-attributing to the survivor would
fabricate provenance and let ER duplicates corroborate). Mechanism: a structural
`edge_provenance.source_node_id` (schema v7, NO FK — explicit purge, not cascade);
`Store.merge_nodes` purges `WHERE source_node_id = alias` synchronously in its transaction
(delete only the alias's provenance, then only edges with no remaining provenance, recompute
`seen_count`); a race guard (`add_edge` pins the source `FOR SHARE`, fails if gone) makes it
impossible for an in-flight enrichment write to leave a ghost after the purge; and
`Swarm.Graph.GC.reap_orphaned_sources/0` is the periodic defensive backstop for legacy/orphaned
rows. The re-enrichment path was already covered by the worker's synchronous `reconcile/2`. **Generation-collision belt (gemini,
2026-07-05):** beyond deferring to GC, `Procedure.steps/3` **itself** computes
`has_generation_collision?` (old+new `has_step` edges under one origin from a re-ingest) and
the descriptor treats any true value as a **hard blocker ⇒ escalate** — so a delayed GC can
never produce a spliced (1,1,2,2,3,3) served procedure. Defence-in-depth at the aggregation
layer, folded into residual #2.

## 3. The tier-routing gate — `sufficient?/2` (Fork B — the center of gravity)

**Decided on the tier-gate blackboard (2026-07-05, codex + gemini — both families; record
`board/research/tier-gate-blackboard.md`). The council CORRECTED the initial lean on three
load-bearing points — those corrections are canon here.**

Placement: intercept the current `:escalate` path in `Swarm.Core.ask/2` **after** retrieval
+ structure building (`Aggregation.entity_profile` / `Procedure.steps`), **before**
`Consilium.deliberate`. The consilium path is behaviourally unchanged — it just also receives
the descriptor/audit as context. No hidden shortcut inside the consilium.

**Contract (CORRECTION 2 — the gate returns a STRUCT, never a rendered string):**

```elixir
@type decision ::
  {:serve, StructuredAnswer.t(), GateAudit.t()}   # evidence-closed atoms + opaque citations
  | {:escalate, GateAudit.t()}                     # falls through to today's consilium path
@spec sufficient?(query :: String.t(), CoverageDescriptor.t()) :: decision()
```

The `:serve` payload is an **evidence-closed** structure of S-P-O atoms + **opaque citation
tokens**; a SEPARATE outer rendering layer turns it into markdown/UI. **The renderer has NO
access to raw hits / profiles / origins** — otherwise "sufficient" becomes a licence to
paraphrase beyond the evidence (codex's underweighted catch: *rendering is a trust boundary*).
`GateAudit` (blockers, slots, descriptor/builder versions) is emitted as telemetry.

### Stage 1 — cheap deterministic structured-coverage check (no LLM)

Escalate immediately unless ALL hold:

- **intent known** — `:unknown`/underspecified intent escalates;
- **intent slots filled** — the query's required slots (for a "how do I X": an
  origin-bounded, ordinal-clean procedure candidate; for "what is X": the definitional
  predicate slots) are present — **incl. applicability / prerequisite / terminal-condition
  slots**;
- **citability** — every served atom is backed by a **current** (non-stale) claim-edge;
- **no unresolved contradiction** — no two in-scope origins assert conflicting steps at the
  same index without a corroboration winner;
- **watermarks valid** — no dependency marked stale in §2;
- **no generation collision** — `has_generation_collision?` false on the served variant;
- **no scope violation.**

Coverage **count** is explicitly NOT the signal — a high edge count with the wrong slots
still escalates.

### Stage 2 — small-model semantic-entailment VETO (DAY 1, not optional — CORRECTION 1)

**The initial lean ("Stage-1-only first, add Stage-2 only if the number demands it") was
REJECTED by the council.** Stage 1 proves a procedure is VALID + CURRENT + CITABLE but NOT
that it *answers this query*: ask "how do I **un**install X" and retrieval pulls the
perfectly-formed "install X" procedure — Stage 1 confidently serves a structurally-clean
WRONG answer, breaking the invariant (gemini's near-miss; = codex's incomplete-but-plausible
sink-risk). So the **Day-1 serve path is Stage 1 AND Stage 2**: after Stage 1 passes, a
**cheap local small-LLM** answers a strict zero-shot entailment YES/NO — *"Does this exact
grounding contain the complete steps to answer the user?"* — and **escalates on anything but
a high-confidence YES**.

**Stage 2 is VETO-ONLY** (may turn `serve → escalate`, **NEVER** recovers a Stage-1
rejection) — this asymmetry keeps the fail-closed invariant a deterministic property, never a
learned one. A future trained MiniLM-scale classifier (Stage 3) **replaces Stage 2's veto
mechanism** for latency (0.5s → ~10ms), preserving veto-only. Measurement governs tuning: if
false-serve is ever measured 0 with Stage-1 alone on the adversarial set, Stage 2 degrades to
a fast-skippable confirm — but it *ships* as the guard, never absent.

### Structural fail-closed (CORRECTION-adjacent — `supported=false ⇒ escalate` as a CODE PROPERTY)

Make a false-serve **unrepresentable** via a typed state machine, not a convention:

```elixir
%RawCoverage{} → validate/1 → {:ok, %ValidatedCoverage{}} | {:error, [blocker]}
```

ONLY `validate/1` mints `ValidatedCoverage`; ONLY `render/1` consumes it → the serve tuple
cannot be constructed without a validated descriptor. A `with` pipeline makes `:escalate` the
default/`_` branch (any failure, timeout, or mismatch falls through). Tests: the property
suite (stale / missing-citation / contradiction / generation-collision / unknown-intent ⇒
`:escalate`) + a **mutation test** (deleting any positive check must turn a green test red) +
**golden tests** (every rendered sentence maps to a citation token).

### The invariant (protects ADR-16's honest-judge trust)

> `supported = false` ⇒ **escalate**. The structured tier **never** emits a step not backed
> by a current claim-edge. A cheap wrong "sufficient" is the one failure that breaks user
> trust — the gate is calibrated to escalate on doubt, never to fabricate.

### Latency self-protection (gemini's sink-risk — never pay gate + consilium)

Emit `gate_duration_ms` telemetry; **circuit-break the gate at `> 1500ms` → default-route
`:escalate`** until the queue clears, so a blocked Stage-2/classifier queue can never make an
ask slower than pure escalation.

**Calibration is measured, not asserted:** on the curated `qa.json` (operator-owned; the
`qa-gold-curation` step) **plus an adversarial procedure suite** (install / upgrade /
uninstall, prerequisites, safety warnings, versioned docs, old/new generations, multi-variant),
report **false-serve rate** (must be ~0 — any false serve blocks broad rollout),
**needless-escalation rate** (70–90% acceptable initially if false-serve is 0), serve rate,
latency p50/p95, and the **blocker distribution**. Label every false-serve by
**missing-slot class** (codex — steers which descriptor slot to strengthen). The go/no-go is a
council on false-serve + needless-escalation.

## 4. Bootstrap — formal corpus first (Fork C, overrides the charter)

- **Phase 1 (running):** the nightly enrichment loop over the formal corpus (wiki/
  runbooks) builds the canonical procedure structure. Plus `concept-synonymy-resolution`
  so vocabulary coheres. Plus the equilibrium run the charter names as the missing piece.
- **Phase 2 (later):** a `glpi-agent` **oracle connector** (`hive/`, ADR-5 `fetch/2`
  contract) mines ticket/change history for **situations → procedure** mappings, variants,
  aliases, and gaps. Provenance-marked (`evidence_kind=claim`, `origin=glpi-agent`,
  `reliability<1`), **group-scoped** (ticket content is intranet — never leaves `hive/` /
  committed files), re-derivable. **Not the foundation** — it annotates the formal map;
  tickets-first would bake incident noise as sanctioned process.

## 5. Scope cut (Fork E)

`Self`-as-data + prediction-as-entities (`world-graph-self-model`) are **out**. Separate
later proposal on the same substrate. This epic ships around the gate.

## 6. Build order (refined by the tier-gate council, 2026-07-05)

1. `concept-synonymy-resolution` (substrate) + curated `qa.json` + let the nightly loop
   reach equilibrium — so lift is measurable. **[DONE — synonymy live-QA'd; qa.json curation
   carded]**
2. Procedure representation (§1) + the `procedure(entity)` aggregation view (§2), incl. the
   group-by-origin ordering and the GC ghost-purge. **[substrate DONE (schema v6); the
   watermark/GC ghost-purge + `has_generation_collision?` belt are the residual §0 below]**
3. **Prerequisites before ANY gate wiring** (residuals card + council Correction 3):
   watermark/GC ghost-purge + `has_generation_collision?` computed in `Procedure.steps/3` +
   two-generation regression test; opaque-origin citation tokens (residual #1); LLM-confirm
   prompt-injection hardening (residual #4). **[DONE]**
4. `Swarm.WorldMap.Coverage.describe/3` (deterministic `%Descriptor{}`, the `blockers` list,
   opaque citations) — pure, TDD. **[DONE]**
5. The typed fail-closed machine (§3): `%Descriptor{} → validate/1 → %Validated{}` — a
   `Validated` is mintable ONLY blocker-free; the fail-closed property sweep. **[DONE]**
6. `Swarm.WorldMap.Gate.sufficient?/1` + the Stage-2 small-LLM entailment **veto** (injectable,
   DAY 1, veto-only) + evidence-closed `render/1` + `%Audit{}`. **[DONE]**
7. Wired into `Core.ask/2`'s `:escalate` interception, **OFF by default** (config/opts gated);
   `GateAudit` telemetry + the 1500ms NOLINK-task circuit-breaker + fail-closed DB-probe. **[DONE]**
8. **[NEXT]** Curate `qa.json` (+ the adversarial procedure suite) → measure false-serve (~0
   hard gate) + needless-escalation + latency p50/p95 + blocker distribution → **council
   go/no-go on the two numbers, then flip the config flag to enable live.**
9. glpi bootstrap (§4 Phase 2).
10. Gate-7 end-to-end: answer-rate + accuracy + **latency** on the curated set,
    before/after; council go/no-go on the two gate rates (§3).

## Open questions

- ~~Does `step_index` live cleanly in the edge property map?~~ **Resolved (2026-07-05,
  §1):** it is a dedicated nullable `step_ordinal` edge column (schema v6), not a
  property-map entry; the `procedure`-kind fallback stays unneeded.
- ~~Stage-1 "intent slots": how are a query's required slots derived cheaply?~~ **Resolved
  (tier-gate council 2026-07-05, §3):** slot SUFFICIENCY is structural (from the retrieval
  shape — procedure candidate present / entity_profile predicate slots filled); a light intent
  tag may only assist classification, never override "no clean candidate ⇒ escalate." The
  SEMANTIC match ("does this candidate answer THIS query") is Stage-2's entailment veto, not a
  structural slot check.
- ~~Stage-2 model choice + confidence threshold?~~ **Resolved to the plan (§3):** Stage 2
  ships Day-1 as a cheap local small-LLM strict-YES/NO entailment veto; the exact model +
  threshold are tuned against the curated + adversarial `qa.json` to keep false-serve ~0
  (measured, not asserted). A trained MiniLM Stage-3 later replaces the veto mechanism for
  latency.
- Remaining for the spike: the exact adversarial-suite composition and the missing-slot-class
  taxonomy for false-serve labelling (folds into `qa-gold-curation`).
