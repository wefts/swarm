# ADR-14: Data/memory model — a coarse lineage node over a stateless content/chunk store

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`. Builds on ADR-4 (graph integrity — guards SHAPE),
ADR-6 (answer-result algebra / embedding namespaces), ADR-11 (zones + claim
typing), ADR-13 (entity resolution), and ADR-9 (workspace, correlated evidence).
Grounded in the first live slice (Phase E2, Wikipedia) and a 3-family consilium
(2026-06-24, recorded in `board/journal.md`).

## Status

Accepted (Phase 1 shipped & live-verified 2026-06-24: the bifurcated content/chunk store,
typed ingest, hybrid retrieval, and a relevance floor are built and validated on a live
96-page Wikipedia slice — answerability 0→100%, recall@1 ~30→98%, recall@5 100%,
fragmentation 0. Phase 2 — source-adapted segmentation + per-type aggregate-vs-identity
vector — remains follow-up, gated on a second source shape. The relevance-floor /
answerability gate added during the build is documented in the spec, §5.1.)

## Record Completeness

Complete

## Context

Swarm's founding idea is **"grep/find on steroids"**: not matching raw strings, but
searching *meaning* over a normalized graph — knowing that two documents about one
thing are **one memory** and that aliases are **one entity**. The first live slice
(Phase E2, ≈1300 Wikipedia nodes) proved we have the **structure** and not the
**meaning**: `Store.upsert_node/3` persists only `(type, key, scope)` + a link graph;
the page **text is dropped**, the node `vec` is **never populated**, and `tier_tools`
search is a `title ILIKE`. A **map without station names** — we know A links to B, not
what A or B is *about*.

Getting the data/memory model wrong early is the expensive failure: once a large graph
exists in the wrong shape, re-modelling it is a migration nightmare. So the model is
**front-loaded** — decided before any ingest code — against four hard constraints:

1. **Confidence is graph traversal.** Confidence is computed by recursive-CTE path
   enumeration over edges; path **enumeration** is the proven scaling wall (ADR-3). More
   nodes ⇒ more fanout ⇒ worse traversal. The unit of memory is therefore also a
   traversal-budget choice.
2. **Correlated evidence must not get worse (ADR-9 workspace).** N derivatives of one
   source must not over-corroborate as if independent. Any grain that mints many sibling
   nodes per source widens this hazard.
3. **Cost asymmetry.** Cheap specialised processes run continuously; expensive LLM calls
   are rare, deliberate escalations. An LLM in the continuous ingest path is
   architecturally wrong unless justified.
4. **Privacy scope is per-node.** Content inherits node scope; finer units multiply the
   scope-tagging surface and the leak risk, and `merge_nodes` must not fuse across scopes.

Four candidate models were laid out and compared (`board/research/data-options.md`):
**C1** coarse node + late-chunk hybrid, **C2** proposition/claim-centric, **C3**
triple/KG-centric, **C4** flat chunk + vector. Three decorrelated critic families
(codex / gemini-3.1-pro / local glm-4.7-flash) stress-tested the tentative C1
recommendation; all three converged in substance on the same mandatory correction
(verdicts SOUND-WITH-CAVEATS ×2, FLAWED ×1 whose fix *was* the converged fix — see
Consilium note). The corrected model is recorded here as the decision.

## Decision

Adopt **C1′** — a **coarse, lineage-bearing graph node** whose text and embeddings live
in a **separate, stateless content/chunk store**. Seven load-bearing parts:

1. **The unit of memory is the lineage node, not the chunk.** A memory node is coarse —
   one per *source document/region* or one per *typed entity/concept* — and is the **sole
   bearer** of identity `(type, key)`, scope, graph edges, `reliability`/confidence,
   provenance, and `merge_nodes` reconciliation. It reuses the existing `node` table and
   `kind` vocabulary (ADR-11); no new evidence-bearing tier is introduced. "**1 source ≈
   1 origin**" so corroboration counts distinct origins, not duplicate fragments.

2. **Content and chunks are a stateless side-store, never packed into the node row.**
   A node's text body and its per-chunk embeddings live in dedicated content/chunk tables
   keyed by `node_id` (FK). Chunks are **retrieval handles only**: they carry text + a
   `vec` + an HNSW index, and they **cannot** vote, link, merge, widen scope, or carry
   independent provenance — they inherit the parent node's scope for filtering. This is
   the bifurcation the consilium made mandatory (HNSW requires one row per vector; a fat
   node row both defeats the index and lets chunks masquerade as evidence → C4 collapse).

3. **The node-level vector is an aggregate/identity vector, not a literal full-document
   mean.** "Embed the whole doc, mean-pool" is **false for long/heterogeneous sources**
   (bge-m3 caps at 8192 tokens; code/logs/JSON/tables/PDFs are not coherent prose). The
   body is partitioned by a **source-adapted** segmenter (windowing for long sources);
   per-partition vectors populate the chunk store; the node `vec` is an aggregate over
   them (or a dedicated identity/topic vector). One cheap embed pass per partition keeps
   ingest continuous; no LLM.

4. **Normalization is the ADR-13 funnel, plus two seams it left open.** Deterministic
   source cleanup at the **connector** → cheap embedding/MinHash candidate-proposal in the
   **kernel** (continuous) → LLM verify **only to confirm** a proposed alias (rare, the
   EDC pattern) → provenance-preserving `merge_nodes` survivorship via a **reversible alias
   table**. The two seams this ADR newly specifies: (a) a **kernel-owned type vocabulary**
   that connectors map *into* (within-type entity resolution is moot if connectors mint
   divergent types — this complements the ADR-4 shape guard); (b) **scope-aware merges** —
   merging a `private` node into a `public` one can leak, so a cross-scope merge is a
   guarded/escalated decision, never an automatic `upsert_node` resolution.

5. **Retrieval is hybrid-then-traverse, all inside Postgres.** Lexical (tsvector/GIN) ∥
   dense (pgvector HNSW over the chunk store), fused by **RRF in SQL**, scope predicate on
   **both** arms → group hits by `node_id` → feed the **native graph traversal** (the
   recursive-CTE confidence machinery) for entity-centric expansion and multi-hop. Every
   result returns **parent node identity + the cited span**. Query shapes the model
   **must** serve: exact-id/alias (lexical), paraphrase/conceptual (dense), multi-hop &
   entity-centric (graph), scope-respecting variants of each. Shapes it **deliberately
   will not** serve now: corpus-wide LLM global summarization (GraphRAG community reports),
   per-query LLM rerank as a default, late-interaction/ColBERT multi-vector.

6. **Semantic enrichment is reward-gated, never the continuous default.** Claims (C2) and
   typed relations (C3) are **enrichment layered onto nodes that already exist**, using the
   existing `kind` vocabulary (`claim`/`derived`) and `Confidence.combine_typed/1` (which
   already collapses LLM-generated kinds into one group, so a burst of claims cannot
   over-corroborate). Enrichment fires on **explicit promotion triggers** (repeated
   retrieval, conflicting evidence, high-value source, user-pinned question,
   confidence-critical path) with a **budget and an observable backlog** — so "enrich
   later" does not become "semantics never". The hybrid-retrieval + citation-graph is a
   **legitimate functional floor**, not a failure state. Cheap-heuristic triple extraction
   is **rejected** — garbage triples poison the graph.

7. **Merge semantics are per-kind and scope-aware.** Because identity has multiple axes
   (source/document vs entity/concept vs claim), `merge_nodes` needs **per-kind rules**:
   what happens to text bodies and chunk sets on merge (union the chunk store under the
   surviving `node_id`; do not silently drop the alias's semantic surface), and the
   re-embed/write-amplification cost of editing a coarse node's body. Cross-scope merges
   are guarded (part 4b).

## Consequences

- **Easier.** The content/`vec` gap closes without worsening ADR-9 or ADR-3: coarse
  lineage nodes keep the graph small and corroboration honest, while a stateless chunk
  store gives day-1 dense recall. Hybrid retrieval is buildable entirely in the existing
  Postgres (tsvector GIN + pgvector HNSW + RRF in SQL) — no new engine, no per-query LLM.
  Enrichment grows **additively** on top of the substrate, so the base decision is
  lowest-regret under uncertainty.
- **Harder.** Two unit *types* now exist (lineage node ⟂ retrieval chunk) and the
  invariant that chunks stay stateless must be **enforced**, not just documented — a
  retrieval API that leaks bare chunks (no parent identity) would erode it operationally.
  A two-stage query (chunk similarity → group by node → traverse) is more complex than a
  flat top-k. Source-adapted segmentation is per-connector work, not a single kernel
  primitive.
- **Impossible (by design, for now).** No corpus-wide LLM summarization, no default LLM
  rerank, no multi-vector late interaction — deliberately out of scope until justified.
- **Open / carried.** The kernel-owned type vocabulary and scope-aware-merge rule are
  specified here but **built** in the implementation campaign. The ADR-9 strength-side
  evidential-origin accounting remains the workspace's open correctness question; this
  model is lineage-aware (part 1) so it does not make it worse, but does not close it.

## Alternatives

- **C2 proposition/claim-centric (rejected as the base).** Best factoid precision, and
  claims map natively to ADR-11 typing — but an LLM propositionizer in the continuous
  ingest path violates the cost asymmetry, and atomic claims explode node count
  (traversal-cost wall) and sibling-per-source corroboration (ADR-9). Retained as
  reward-gated enrichment (decision part 6).
- **C3 triple/KG-centric (rejected as the base).** Maps onto the typed node+edge graph and
  is strong for multi-hop — but triples carry no embeddable prose body, so it does **not**
  close the content gap ("what does the text say"), and relation extraction is again an
  LLM in the continuous path. Retained as enrichment (typed relations).
- **C4 flat chunk + vector (rejected — the anti-pattern).** Cheapest to build, but every
  chunk a node is the **worst** case for ADR-9 (N chunks/source over-corroborate) and the
  traversal wall, multiplies scope surface, and wastes the graph that is Swarm's whole
  differentiator. It is the migration nightmare the charter warns against.
- **Pack text + chunk-vectors into the node row (rejected).** The naive reading of C1.
  Defeats the HNSW index (one row per vector), bloats traversal I/O, and lets chunks
  become evidence-bearing — collapsing C1 into C4. The bifurcated store (decision part 2)
  is precisely the fix all three critics demanded.

## Consilium note (3 decorrelated families, 2026-06-24)

Recorded in full in `board/journal.md`. **codex** (OpenAI) → SOUND-WITH-CAVEATS: chunks
retrieve spans only; only parent/entity/claim nodes carry lineage/scope/edges/merge;
unnamed failure = **identity granularity** (source vs entity vs claim are different
axes → per-kind merge rules). **gemini-3.1-pro** (Google) → SOUND-WITH-CAVEATS: formally
**bifurcate** `lineage_nodes` ⟂ `retrieval_chunks` (HNSW, stateless, FK); never store
chunks in the node row; watch merge collisions + write-amplification on fat payloads.
**glm-4.7-flash** (local) → FLAWED, but its fix ("Content Decoupling — move `text_body`
out of the node into a sibling table; node holds an identity vector + `content_id`") **is
the converged fix**; its FLAWED targeted "C1 with text in the node row", not the
bifurcated model. Per `memory/decorrelated-critics.md`, a lone harsh verdict is weighed
point-by-point, not treated as binding; here it reinforced rather than dissented. All
three corrections are folded into decision parts 2, 3, 5, 6, 7.

## References

- `board/research/data-foundation-research.md` — the research charter (the declarative output).
- `board/research/data-landscape.md` (step 1) · `board/research/data-options.md` (step 2) ·
  `board/journal.md` 2026-06-24 entries (steps 1–3, consilium verdicts).
- `swarm/docs/design/data-memory-model.md` — the implementable spec for this decision.
- `board/todo/ingest-persist-content.md` — the consumer this unblocks (impl campaign).
- ADR-4 (shape) · ADR-6 (embedding namespaces) · ADR-11 (zones/claim typing,
  `combine_typed`) · ADR-13 (entity resolution funnel) · ADR-9 workspace (correlated evidence).
