# ADR-16: Retrieval lexical arm — adopt pg_search/ParadeDB (Tantivy BM25 in Postgres)

## Status

Proposed — gated by a feasibility spike (`board/todo/retrieval-pg-search-spike.md`);
flips to Accepted only after the spike is green and a decorrelated council signs off.

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
