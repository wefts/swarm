---
status: draft
adr: workspace ADR-17 (Proposed 2026-07-04)
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

- `has_step` — edge to a step's content node; carries an integer **`step_index`** property
  (in the edge's existing property map, not a new column) for ordering.
- `requires_tool` — edge to the tool/system a step uses.
- `applies_to` — edge to the situation/scope the procedure covers.

Every step edge keeps `origin` + `reliability` + reversibility exactly like any claim edge
(ADR-13). **Reification stays closed:** a step is an edge asserting "this source says step
N is X", never a first-class truth-node.

**Load-bearing constraint (the council's sharpest catch):** a procedure may be described by
more than one source. The aggregation **groups `has_step` edges by `origin` FIRST, then
orders by `step_index` within each origin** — never interleaves indices across sources
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
3. group by `origin`, order steps by `step_index` within origin;
4. attach each step's citation (source node) — every emitted step is **citable**;
5. compute a **coverage descriptor** for the gate (§3): which intent slots are filled, by
   how many independent origins, at what reliability, whether any dependency watermark is
   stale, whether contradictions are unresolved.

**Freshness (Fork D):** nothing is cached. The view runs on every read over **current**
edges. A step whose source node's `content_watermark` has moved since the edge was written
is marked **stale** and excluded from the "supported" set (the gate then likely escalates).
**Ghost-procedure hazard:** when a source node is deleted or merged, the GC/merge path
(`Swarm.Graph.GC` / `merge_nodes`) **must purge its derived `has_step`/`requires_tool`
edges** — an orphaned step-edge pointing at a dead source would otherwise stitch a phantom
step. Add this to the GC contract + a regression test.

## 3. The tier-routing gate — `sufficient?/2` (Fork B — the center of gravity)

Wired into `Ask` as a tier **between `tools` and `escalate`**. Given the query + the
coverage descriptor (§2):

### Stage 1 — cheap deterministic structured-coverage check (no LLM)

Escalate immediately unless ALL hold:

- **intent slots filled** — the query's required slots (for a "how do I X": a procedure
  candidate with ≥1 ordered step) are present;
- **citability** — every candidate step is backed by a **current** (non-stale) claim-edge;
- **no unresolved contradiction** — no two in-scope origins assert conflicting steps at the
  same index without a corroboration winner;
- **watermarks valid** — no dependency marked stale in §2.

Coverage **count** is explicitly NOT the signal — a high edge count with the wrong slots
still escalates.

### Stage 2 — optional small-model sufficiency confirm

If Stage 1 passes, optionally ask a **cheap, fast model** a strict YES/NO: *"Does this
exact grounding contain the complete steps to answer the user?"* Accept only on a
high-confidence YES; anything else escalates. (This is a guard against a structurally-
complete-but-semantically-wrong match, not the primary signal.)

### The invariant (protects ADR-16's honest-judge trust)

> `supported = false` ⇒ **escalate**. The structured tier **never** emits a step not backed
> by a current claim-edge. A cheap wrong "sufficient" is the one failure that breaks user
> trust — the gate is calibrated to escalate on doubt, never to fabricate.

**Calibration is measured, not asserted:** on the curated `qa.json` (operator-owned; the
`qa-gold-curation` step), report both **false-serve rate** (gate said sufficient, answer
wrong/incomplete — must be ~0) and **needless-escalation rate** (gate escalated where
structure sufficed — the cost we're buying down). The go/no-go is a council on these two
numbers.

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

## 6. Build order (refined in the epic)

1. `concept-synonymy-resolution` (substrate) + curated `qa.json` + let the nightly loop
   reach equilibrium — so lift is measurable.
2. Procedure representation (§1) + the `procedure(entity)` aggregation view (§2), incl. the
   group-by-origin ordering and the GC ghost-purge.
3. The tier-routing gate (§3) — Stage 1 first, measure; Stage 2 only if Stage 1's
   false-serve rate needs the semantic backstop. Wire into `Ask`.
4. glpi bootstrap (§4 Phase 2).
5. Gate-7 end-to-end: answer-rate + accuracy + **latency** on the curated set,
   before/after; council go/no-go on the two gate rates (§3).

## Open questions for the spike

- Does `step_index` live cleanly in the edge property map, or does ordered-step aggregation
  need an index the current schema can't express (→ the `procedure`-kind fallback)?
- Stage-1 "intent slots": how are a query's required slots derived cheaply (a light intent
  classifier vs the retrieval shape itself)?
- Stage-2 model choice + the confidence threshold that keeps false-serve ~0 without
  escalating everything.
