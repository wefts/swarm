# ADR-16: Retrieval lexical arm — adopt pg_search/ParadeDB (Tantivy BM25 in Postgres)

## Status

Proposed — the feasibility spike RAN (2026-06-30, `board/done/retrieval-pg-search-spike.md`)
and is **green on its primary gates** (BM25 beats the native baseline on relevance; no-leak
filter-before-rank holds; index stays fresh under writes), but the decorrelated council returned
**GO-WITH-CONDITIONS** — so this stays **Proposed**, NOT Accepted, until the conditions below are
met. Full rewrite now would be premature. See "## Spike result".

## Record Completeness

Complete (decision direction); implementation detail pending the spike.

## Context

- `Swarm.Graph.Retrieval` fuses a lexical arm (`ts_rank` over `chunk.text`) with a
  dense arm (pgvector cosine over `chunk.vec`). **`node.key` (the title) is never a
  ranking signal, and `node.vec` (the title/identity embedding) is unused in search.**
  A page whose title *is* the query therefore competes only on body chunks and ranks
  mid-pack — empirically confirmed 2026-06-30: "What is Nebula Public IP?" → the page
  titled "Public IP" (#1530, body + value chunks present and embedded) is absent from
  the top-12 by body-lexical but ranks #1 on a hypothetical title arm.
- Postgres FTS with the `simple` config does no stemming/synonyms, and `ts_rank` is
  not true BM25. We are hand-rolling a weaker Lucene in SQL; the "title-arm" fix is
  literally *boost the title field* — a one-liner in any Lucene engine.
- **Principle (operator):** push deterministic work into search/structure; reserve the
  LLM for **curation** — claim extraction, entity resolution, facet/category
  assignment, relationship-building — never the query path. A stronger deterministic
  retrieval floor yields better seeds for the curator → richer structure → better
  retrieval (a virtuous loop, on-thesis with cost-asymmetry).
- External engines (ES/Solr) would move the **no-leak boundary out of Postgres** and
  add a JVM cluster on an air-gapped single box — unacceptable against the one hard
  invariant (scope-enforced privacy) and the local-first constraint.

## Decision

Adopt **pg_search / ParadeDB** (Tantivy BM25 as a Postgres extension/index) as
Swarm's **lexical retrieval arm**, replacing the hand-rolled `ts_rank` arm.
Field-boosted BM25 over **`node.key` (title) + `chunk.text`**, fused with the existing
pgvector dense arm (hybrid BM25 ⊕ dense). It stays **inside Postgres** → the scope
predicate still enforces no-leak, one store, no extra service.

**Build from source, we own it:** compile the extension in a multi-stage container
against the exact PG major of the deployment Postgres, target ARM64, push the
Postgres-with-extension image to the local registry. Air-gap = carry the built image.

**Burden of proof (council 2026-06-30 — adopted):** the **native baseline comes
first** — a weighted-`tsvector` title fix (`setweight` title=`A` ‖ body=`D`,
`ts_rank_cd`, `pg_trgm` for short title queries; `board/todo/retrieval-title-arm.md`).
pg_search is the **candidate upgrade**, adopted only if the spike shows it
**beats that baseline** on relevance enough to justify the operational dependency —
not merely if it builds. (The council's framing: "the right *spike*, not yet the
right *decision*.")

**Gated by the feasibility spike:** ARM64 build-from-source · a relevance win over
the native baseline (especially title-only / short queries) · **filter-before-rank
under scope** — a bm25 top-K operator must not rank globally then filter (that would
gut scoped recall and risks term-existence leakage); prove filter-before-rank or
deep-enough candidates under selective scopes · write/REINDEX behaviour under the
continuous enrichment write-loop · backup/restore/REINDEX/recovery in air-gap. Status
flips to Accepted only on a green spike + a decorrelated ≥2-family council.

## Council (pre-spike, 2026-06-30)

Decorrelated pair — **codex (gpt-5.5)** + **llama3.3:70b (Meta)** — both
**SOUND-WITH-CAVEATS**, convergent. They corrected the framing (this ADR adopts the
correction): pg_search is the right *spike*, not yet the right *decision* — **invert
the burden of proof** so the native weighted-FTS title fix is the baseline pg_search
must beat. Both flagged the same operational risks (version-lock, write-amp, hybrid
score-fusion, maturity/abandonment); codex added the load-bearing ones folded into the
spike gates above (**filter-before-rank under scope**, query-semantics drift = silent
"memory loss", air-gap recovery). On **LLM-as-curator: SOUND** — caveat: curator output
must **inherit scope + carry provenance** (never merge a private and public entity so a
private fact leaks through a public node); Swarm's edges already carry origin +
provenance + scope (workspace ADR-13). **Most important (codex):** scope filtering must
hold inside the authoritative Postgres boundary on *every* path — rank, snippet, facet,
count, traversal; if BM25 improves relevance but weakens no-leak, it is disqualified.

## Spike result (2026-06-30, `board/done/retrieval-pg-search-spike.md`)

Ran the relevance-first path (operator's call): prebuilt ParadeDB image (PG18/arm64, `pg_search`
0.24.1 + `pgvector` 0.8.2) on an **isolated sandbox DB** seeded read-only with the full real corpus
(1626 group nodes / 8728 chunks from staging `swarm_prod`). bm25 index over `chunk.text` +
`node.key` (title field-boosted), `scope` a filter field. Compared the BM25 lexical arm against the
just-shipped native lexical arm (Phase 1; for this gold set the dense arm adds nothing, so
lexical-only is the complete A/B). 7-question labeled gold ("what is X", group scope, recall@10):

| arm | recall@10 | MRR | leads | notes |
|---|---|---|---|---|
| native (ts_rank body + title-arm boost, tw=30) | 0.857 | 0.519 | 3/7 | Kubernetes page unreachable at any title weight |
| BM25 body+title, boost=2 | **1.000** | **0.732** | **4/7** | recovers the Kubernetes title-only page (rank 8) |
| BM25 boost=4 / 8 | 0.857 | 0.714 / 0.690 | 4/7 | MRR win robust across boost; recall@10=1.0 is boost-fragile |

**Gate 3 (beats baseline): PASS** — BM25 beats on all three metrics; the MRR win (+33–41%) is robust
across the boost sweep; the recall win (Kubernetes recovery) is real but boost-sensitive. **Gate 4
(filter-before-rank / no-leak): PASS** — EXPLAIN shows the `scope:group` predicate executed INSIDE the
Tantivy query (`must` clause) by the ParadeDB index scan; a cross-scope injection test (synthetic
public doc + the group corpus) confirmed a public viewer sees 0 group rows via rank, score, or count.
**Gate 1 (build + CREATE INDEX bm25): PASS** (prebuilt). **Gate 5 (freshness): PASS** —
UPDATE/INSERT/DELETE reflect in the bm25 index immediately, no manual REINDEX (enrichment-loop safe).

**Council (codex gpt-5.5 + llama3.3:70b, both GO-WITH-CONDITIONS, convergent):** the win is real but
(a) the gold is small-N (7) and all title-lookups → structurally favours title-boosting; (b) boost=2
was tuned on the eval set (overfit risk — only the MRR win is robust); (c) **the Kubernetes recovery is
precisely the native title-bypass that Phase 1 DEFERRED** — so the honest comparison is BM25 vs a
*repaired* native baseline (a title-floor/bypass arm, a swarm-only change, no new dependency). If the
cheap native bypass recovers Kubernetes and performs near BM25, the extension is hard to justify.

**Conditions before flipping to Accepted (all must pass):**
1. **Repaired-native comparison first** — add the deferred native title-bypass arm and re-run; only if
   BM25 still clearly beats *that* is the extension justified.
2. Larger **frozen holdout** labeled set (diverse, not only title-lookups; near-dup titles; scope
   collisions); freeze the boost/scoring recipe before the holdout; report per-query wins/losses.
3. **PG16** production image built from source → local-registry (pinned, reproducible, air-gap
   installable) — the spike used PG18.
4. No-leak regression **suite** across rank, count, pagination, deletion, scope-mutation, dup-titles,
   malformed queries.
5. Sustained write/vacuum/index-growth test under enrichment-like load; backup/restore/REINDEX recovery
   rehearsed; analyzer/tokenizer drift documented + accepted (Tantivy ≠ PG `simple`).
6. Keep **RRF** (no raw BM25⊕vector score fusion); keep the native arm behind a feature flag until
   production burn-in is clean.

## Consequences

- Lucene-grade lexical: native field boost, phrase, fuzzy, analyzers, real BM25 —
  fixes the title-blindness class without bespoke ranking code.
- New DB dependency: the deployment Postgres image carries the extension (rebuild +
  version-lock to the PG major; bm25 index maintenance / write-amplification on
  enrichment writes).
- **No-leak must be re-proven** through the bm25 query path (spike step 4).
- Does **not** remove the facet-ingest need: category faceting still requires the field
  populated at ingest; pg_search only makes it fast once it exists. Complementary.
- Dense/semantic stays on pgvector (an embedding model, not a per-query LLM); full
  power = the BM25 ⊕ dense hybrid.
- **Filter-before-rank under scope** (council, load-bearing): a bm25 top-K may rank
  globally then filter → poor scoped recall + term-existence leakage. The spike must
  prove filter-first or deep-enough candidates under selective scopes.
- **Query-semantics drift:** Tantivy tokenization/stemming differs from the current
  FTS → retrieval can silently change (users feel it as "memory loss"). Pin + verify
  the analyzer against the current behaviour.
- **Maturity / abandonment:** a young extension going unmaintained can freeze the
  Postgres major — foundational-infra risk, not a minor dependency.
- Keep **RRF** (it rank-normalizes); do **not** fuse raw BM25 scores with vector
  distance — tune candidate depth / per-arm cutoffs, not raw-score weighting.
- The **native weighted-FTS title fix is the baseline, done first**
  (`board/todo/retrieval-title-arm.md`); it is also the fallback if the spike walls.

## Alternatives

- **Stay PG-FTS + bespoke title-arm** — cheapest, no dependency, but a permanently
  weaker Lucene reimplemented in SQL. Kept as the fallback, not the target.
- **External ES/Solr** — mature, but moves no-leak out of Postgres + a JVM cluster on
  an air-gapped box. Rejected.
- **External light libs (embedded Tantivy / Meilisearch / Typesense)** — lighter than
  ES but still a second store with the scope boundary leaving Postgres. Rejected in
  favour of in-Postgres pg_search.
- **Better native PG config (language stemmer + synonym dict)** — a partial gain
  without BM25 quality or field-boost ergonomics; insufficient alone.
