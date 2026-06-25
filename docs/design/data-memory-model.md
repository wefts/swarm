---
status: built (Phase 1; §5.1 + Phase-2 items as noted)
implements: "swarm ADR-14 (Accepted) — ../decisions/0014-data-memory-model.md"
owner: swarm
---

# Spec: Data/memory model — coarse lineage node + stateless content/chunk store

Implementable spec for swarm ADR-14 (C1′). It says *what to build* precisely enough to
implement against; it does **not** authorise building it (that is the
`ingest-persist-content` campaign). Extends the ADR-4 contract; reuses the ADR-11 `kind`
vocabulary and ADR-13 normalization funnel. Reconciliation with ADR-4/9/11/13 is the
last section.

## 0. The shape in one picture

```text
                 (graph: identity, scope, edges, merge, confidence)
   node ──links_to/relates──▶ node ──────────────▶ node
    │  (coarse: 1 source-region OR 1 typed entity; the ONLY evidence-bearing tier)
    │
    │ 1:N  (FK node_id; stateless; inherits node.scope; NO edges/merge/lineage)
    ▼
  content ──1:N──▶ chunk
   (raw body)      (text span + vec[pgvector,HNSW] + ordinal)   ◀── dense retrieval here
```

Two tiers, one rule: **the node is memory; the chunk is a handle.** A chunk never appears
in a result without its parent node identity.

## 1. Data shapes

### 1.1 `node` (existing table — unchanged structurally)

Reuses today's columns: `(id, type, key, vec, embed_model, scope, kind, reliability,
provenance, claimed_by, lease_until, fence, created_at, updated_at)`.

- **`type`** is the entity-kind / identity axis (`source`, `concept`, `event`, `user`, …)
  drawn from the **kernel-owned type vocabulary** (§3.1). Identity = exact `(type, key)`.
- **`kind`** (ADR-11) is the lifecycle/zone class: `observation` (default, external
  evidence) for ingested source/entity nodes; `claim`/`derived` for reward-gated
  enrichment (§4).
- **`vec`** holds the node-level **aggregate/identity** vector (§2.3), NOT a literal
  full-document mean. `embed_model` stamps the namespace (ADR-6).
- **`scope`** is the privacy boundary; content + chunks inherit it.

### 1.2 `content` (new — one row per node that carries text)

`(node_id FK→node ON DELETE CASCADE, body text, body_hash, source_ref, segmenter,
created_at)`. **No `scope` column** — scope is read through `node.scope` (single source
of truth; never duplicated, so it cannot drift). Stateless w.r.t. the graph: no edges, no
reliability, no provenance of its own (provenance lives on the node). `body_hash` (e.g.
SHA-256 + a MinHash/SimHash signature) supports near-duplicate detection at the
observation layer (the ADR-9 lever, §6).

### 1.3 `chunk` (new — one row per retrieval span; the HNSW-indexed tier)

`(id, node_id FK→node ON DELETE CASCADE, ordinal int, text text, vec vector,
embed_model text, token_count int)`. **Invariants (enforced, not just documented):**

- a chunk has **no** `scope` column of its own — retrieval filters chunks by joining to
  `node.scope` (single source of truth, no scope drift);
- a chunk has **no** graph edges and is **never** an endpoint of `node`-level edges;
- a chunk is **never** returned without `node_id` + ordinal (the "cited span" rule);
- `vec` is indexed by **HNSW** (`vector_cosine_ops`); one row per vector.

### 1.4 edges (existing — unchanged)

Edges connect **nodes only** (ADR-4 visibility invariant: edge scope ≤ narrowest
endpoint). Chunks are not nodes, so the invariant is untouched.

## 2. Normalization & content/embedding pipeline (ingest, continuous, NO LLM)

Stages, in order; every stage is cheap/deterministic so it runs on the continuous path.

1. **Connector fetch** (ADR-5 `fetch/2`) → raw source payloads (paginated to exhaustion).
2. **Connector deterministic cleanup** (ADR-13 Layer 1): encoding/whitespace, source-id
   normalization, source-declared equivalences (URL-decode, MediaWiki `normalized` +
   `redirects` resolved to a fixed point *before emit*). Decidable from the source alone.
3. **Type binding**: connector maps each emitted unit onto a **kernel type** from the
   controlled vocabulary (§3.1) — not a connector-chosen string.
4. **Node upsert** (`upsert_node/3`): identity by `(type, key)`; the kernel alias seam
   (ADR-13 Layer 2) consults the **reversible alias table** before minting (§3.2).
5. **Source-adapted segmentation**: a per-connector segmenter partitions the body
   (prose → semantic/recursive; code/logs/JSON/tables → structure-aware windows ≤ bge-m3's
   8192-token limit). Emits ordered partitions.
6. **Embed** (cheap, local, bge-m3, one pass per partition): write `content` (body) +
   `chunk` rows (text + `vec` per partition). Stamp `embed_model`.
7. **Node-level vector** (§2.3): aggregate the partition vectors into `node.vec` (or embed
   a dedicated identity/topic string for entity nodes).

> **No LLM anywhere in stages 1–7.** Proposition/relation extraction is §4 (enrichment),
> off this path.

### 2.3 The node-level vector

`node.vec` is, per `type`, **either** a deterministic aggregate over the node's
`chunk.vec` set (mean / length-weighted mean) **or** a dedicated identity/topic vector
(embed the canonical name + short descriptor) — explicitly **not** a single
full-document embedding (false for long/heterogeneous sources, "mean-pooling drift").
Prose source nodes lean aggregate; pure entity/concept nodes lean identity vector. Which
applies per `type` is settled by a recall measurement in the build campaign (§7), not
guessed here. Re-aggregation is a cheap recompute when the chunk set changes
(§7 write-amplification).

> **Status (Phase 2, 2026-06-25): the per-type choice is DEFERRED, not settled.** Retrieval
> is entirely **chunk-level** (`chunk.vec`); `node.vec` is currently **write-only** — set on
> embed but read by no retrieval/gate/core path. With no consumer, a recall measurement
> cannot distinguish aggregate from identity, so the choice is deferred (the aggregate mean
> remains the harmless default) until a node-level dense consumer exists. Picking it now
> would be guessing at something nothing reads.

## 3. Normalization seams this spec newly specifies

### 3.1 Kernel-owned type vocabulary

A closed `type` vocabulary in the graph contract (sibling to ADR-4's `scopes/0` and
ADR-11's `kinds/0`), e.g. `Contract.types/0`. Connectors **map into** it (stage 3);
within-type entity resolution (ADR-13) is only meaningful once types are canonical. A
connector emitting an unknown type fails the write-validated contract (fail-loud), as
ADR-4 already does for scope/kind.

### 3.2 Reversible alias table + scope-aware merge

- **Alias table** `(type, alias_key) → canonical_key`, consulted by `upsert_node` before
  minting (the standing-table form carded in `board/todo/entity-resolution`). Reversible
  and audit-friendly — preferred over eager collapse.
- **Candidate proposal (continuous, cheap):** embedding-blocking (pgvector ANN over
  `node.vec`) and/or MinHash over `content.body_hash` propose "these may be the same".
- **Confirm (rare, reward-gated):** an LLM confirms a *proposed* pair only (EDC pattern) —
  never bulk extraction.
- **Merge (`merge_nodes/3`, per-kind + scope-aware):** the *common* survivorship re-points
  edges, unions distinct provenance, **unions the chunk store** under the surviving
  `node_id` (never drops the alias's spans), recomputes `seen_count`, drops merge-induced
  self-loops (ADR-13). The per-`type`/`kind` differences (the campaign implements these;
  the spec fixes the semantics):
  - **`source`/document nodes** — *near-duplicate* of the same source: union chunk sets,
    keep the body with the higher-fidelity/most-recent `body_hash`, re-aggregate `node.vec`.
    Two *distinct* sources about one topic are **not** merged at the source axis — they
    link to a shared entity node instead (this is the identity-granularity resolution:
    document identity ≠ topic identity).
  - **`concept`/`entity` nodes** — alias/redirect collapse (the ADR-13 case): union edges
    and provenance; body/chunks usually absent (identity vector), so re-embed the canonical
    descriptor.
  - **`claim`/`derived` nodes** — merge only *equivalent* claims; provenance union must
    preserve **distinct evidential origins** (ADR-9) so corroboration is not faked;
    `combine_typed` already prevents inflation.
  - **A cross-scope merge (private↔public) is refused/escalated**, never automatic — for
    every kind. The surviving node's scope is never silently widened.

## 4. Enrichment (reward-gated, OFF the continuous path)

Claims (C2) and typed relations (C3) attach to nodes that already exist:

- **Trigger** (any of): repeated retrieval of a node, conflicting evidence on a path,
  high-value source, user-pinned question, confidence-critical traversal. Governed by a
  **budget** and an **observable backlog** (no silent "never").
- **Produce**: `claim`/`derived` nodes (ADR-11 `kind`) linked to their evidence; typed
  relation edges between entity nodes.
- **Corroboration safety**: `Confidence.combine_typed/1` already collapses all
  LLM-generated kinds into ONE group (claim/hypothesis/derived → max-within), so a burst
  of enrichment claims **cannot** inflate confidence — the ADR-9 defense already covers it.
- **Rejected**: cheap-heuristic triple extraction (poisons the graph).

## 5. Retrieval interface (hybrid-then-traverse)

A two-stage query, all in Postgres, scope-filtered, no per-query LLM:

```text
stage 1  (find candidate spans)
  lexical:  tsvector/GIN over chunk.text  ┐
  dense:    pgvector HNSW over chunk.vec  ┘  → RRF fuse (in SQL)
  WHERE join node.scope ∈ asker-visible scopes        ◀── privacy on BOTH arms
  → group hits by node_id  (collapse spans → memories)

stage 2  (turn memories into THE memory)
  feed node_ids into the recursive-CTE graph traversal:
  entity-centric expansion + multi-hop; existing confidence calculus scores paths
  → answer-result algebra (ADR-6): found / partial / not_found / error
  → every result carries {node identity, cited span(s), confidence}
```

- **Must serve**: exact-id/alias (lexical arm), paraphrase/conceptual (dense arm),
  multi-hop & entity-centric (graph), scope-respecting variants of all.
- **Deliberately will NOT serve (now)**: corpus-wide LLM global summaries, default LLM
  rerank, late-interaction/ColBERT. (A small **local** cross-encoder rerank is the only
  sanctioned escalation, for hard/ambiguous queries — opt-in, not default.)

This stage-1+stage-2 pipeline — hybrid retrieval over a citation/link graph, **before any
enrichment fires** — is a **legitimate functional floor**, not a degraded mode: it already
delivers "grep/find on steroids" (keyword precision + meaning + multi-hop). Enrichment (§4)
raises the ceiling; it is not a precondition for the model being useful.

### 5.1 Relevance floor & answerability gating (built in Phase 1)

The ADR's stage-1 fuse, taken naively, cannot say "I don't know": the dense arm always
returns nearest neighbours, so an out-of-scope query still gets ranked results. Phase 1
added a **relevance floor** that makes retrieval answerability-aware. This is the one
mechanism not contemplated in the ADR's seven parts; it is load-bearing in production.

- **Carry the absolute cosine, not just the rank.** The fused SQL surfaces the dense arm's
  **absolute cosine** (`1 - distance`) and a per-chunk **lexical-hit flag**, alongside the
  RRF rank. (Diagnosis 2026-06-24: the early "embedding hubness" symptom was largely an RRF
  artefact — RRF's `1/(k+rank)` discards the absolute cosine that *does* separate in- from
  out-of-scope; chunk vectors are already unit-norm.)
- **Gate, then rank.** A chunk passes the **relevance gate** iff it had a lexical hit **OR**
  `cosine ≥ floor` (default `0.45`; `config :swarm, :retrieval, floor:` or per-call `:floor`).
  RRF ranks only the survivors, so a "magnet" near-neighbour below the floor is dropped
  **before** it can outrank the true answer (this is what lifted recall@1 ~30→98%).
- **Answerability.** A node with no surviving chunk is dropped; **no survivors ⇒ `:not_found`**
  (the ADR-6 answer-result algebra), not a list of low-confidence guesses. A memory now reports
  `relevance` (cosine) distinct from `confidence` (node trust).
- **Calibration caveat (Phase 2).** The floor is **absolute**; paraphrase / cross-lingual
  (UA/FR→EN) hits have lower cosine. On the verbatim-ish slice it held recall@5 100% to 0.55,
  and the conservative 0.45 default cleared cross-lingual hits via cosine. A **relative gate**
  (`cos ≥ top − δ`) + a minimum lexical score is the Phase-2 generalization
  (`board/todo/data-impl-vector-recall`), to validate across ≥2 source shapes.

### 5.2 Answer-path integration — `Core.ask` (built in Phase 1)

`Core.ask`'s default retriever is the §5 hybrid content path (relevance-floored, §5.1)
**merged with** a title/identity **key arm**. To stop the key arm re-introducing false
positives the floor removed:

- **Key-arm gate (`gate_key_hits`).** A title/key hit must match **≥ ceil(n/2)** of the
  query's significant terms as **delimited tokens** (not substrings) — so "war" ↛ "Award",
  "change" ↛ "exchange". (Reuses the T8 owner-boundary tokeniser.)
- **Owner queries stay key-only.** "my X" resolves through the identity/key arm, never the
  dense arm, preserving the T8 contract (viewer-scoped or `identity_required`).
- **Known residual gaps** (carded, not yet closed): a key-arm exact match against a
  **content-less stub** title can still false-`found` an out-of-scope query
  (`board/todo/key-arm-answerability`); `"my"` *inside* a title trips the ownership path
  (`board/todo/first-person-false-ownership`).

### 5.3 Weighted RRF — protect exact hits without losing paraphrase (Phase 2, built)

Card 7 measured the two arms separately on a 2-source slice and found a real ranking
defect the equal-weight fuse caused, plus the reason the dense arm must stay:

- **Dense is essential.** On paraphrase queries (locally-generated NL questions, words
  differing from the source) the lexical arm gets ~0–3% recall@5; hybrid reaches ~72%
  on **both** source shapes (intranet + Wikipedia). The dense arm is the only thing
  that answers a natural-language question — not optional.
- **But dense demoted exact hits.** After structure-aware chunking (§2 stage 5) made
  chunks finer, a multi-chunk dense "magnet" node could out-accumulate a single exact
  **lexical** hit; an ablation showed 100% of the lost cases were exact-lexical hits
  demoted by dense fusion (0 were missing/mis-scoped chunks).
- **Fix: weighted RRF.** The fused SQL scales the lexical term by `lex_weight` and the
  dense term by `dense_weight` (`config :swarm, :retrieval`; per-call overridable).
  Because a paraphrase query has **no lexical rows**, raising `lex_weight` cannot change
  paraphrase ranking — it only floors exact keyword hits on verbatim/keyword queries.
  Tuned by sweep to **`lex_weight: 3.0`, `dense_weight: 1.0`**: group verbatim hybrid
  recall@5 94.7→100% and MRR 0.687→0.878, public verbatim MRR 0.966→0.99, while group
  paraphrase recall held (71.7→70.0%, MRR 0.437→0.456). The relevance floor (§5.1) still
  gates dense-only hits on absolute cosine; weighting is orthogonal to it.

## 6. Reconciliation with existing canon

- **ADR-4 (graph integrity — shape).** Unchanged for nodes/edges; chunks/content are a
  new validated shape (FK, required fields). The new **type vocabulary** (§3.1) extends
  the same write-validated-contract pattern (`Contract.types/0` beside `scopes/0`,
  `kinds/0`). Edge visibility invariant untouched (chunks are not endpoints).
- **ADR-9 (workspace — correlated evidence).** **Strengthened, not strained.** Coarse
  "1 source ≈ 1 origin" nodes keep corroboration counting distinct origins; chunks are
  stateless so they cannot corroborate; `combine_typed` collapses enrichment claims;
  MinHash/`body_hash` (§1.2) flags N-derivatives-of-one-source at the observation layer.
  The strength-side evidential-origin accounting stays ADR-9's open problem — this model
  does not worsen it.
- **ADR-11 (zones + claim typing).** Reused directly: ingested nodes are `observation`;
  enrichment is `claim`/`derived`; reward-gated persistence is exactly the §4 trigger
  model; `combine_typed` is the corroboration guard.
- **ADR-13 (entity resolution).** This spec **is** the funnel's full shape: Layer 1
  (connector cleanup) = stage 2; Layer 2 (kernel alias seam + `merge_nodes`) = §3.2; it
  adds the two seams ADR-13 left open (type vocabulary, scope-aware merge) and the
  reversible standing alias table the follow-up card flagged.

## 7. Known costs / open implementation questions (for the build campaign)

- **Write-amplification**: editing a coarse node's body re-segments → re-embeds its chunks
  → re-aggregates `node.vec`. Bound by `body_hash` (skip unchanged) and per-partition
  diffing (re-embed only changed windows).
- **Segmenter ownership**: prose vs code/log/JSON segmenters are per-connector; only the
  *contract* (ordered partitions ≤ token limit) is kernel-owned.
- **Aggregate-vs-identity vector**: whether `node.vec` is a chunk-aggregate or a separate
  identity vector may differ by `type` — to be settled with a recall measurement in the
  build campaign, not guessed here.
- **Alias-table population**: source-declared equivalences first; embedding-candidate soft
  matches behind the rare LLM-confirm gate.
