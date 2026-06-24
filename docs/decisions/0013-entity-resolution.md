# ADR-13: Entity resolution — two-layer identity, source-normalisation now + a kernel alias seam

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`. Builds on ADR-4 (graph integrity — guards SHAPE) and
ADR-9 (workspace, correlated-evidence) and is grounded in the first live slice
(Phase E2, Wikipedia).

## Status

Accepted (layers 1 + 2 built and proven on real data — see Consequences; a
*standing* alias table consulted automatically by `upsert_node` remains future,
carded in `board/todo/entity-resolution`)

## Record Completeness

Complete

## Context

`Swarm.Graph.Store.upsert_node/3` resolves identity by an **exact** `(type, key)`.
The write-validated schema (ADR-4) guards a node's SHAPE, never its IDENTITY. Mocks
used clean keys, so this was invisible until real data: the first live Wikipedia
slice (1313 article nodes) fragmented immediately, in two distinct classes pinned
as regression fixtures in `kernel/test/swarm/connector/wikipedia_test.exs`:

1. **Source encoding.** A link target arrived percent-encoded —
   `%21%21%21 (album)` — and became its own node, distinct from `!!! (album)`.
2. **Source aliasing / redirects.** Internal-case variants the source treats as one
   page (`Allmusic`/`AllMusic`, `Alessandra de Rossi`/`Alessandra De Rossi`,
   `Michael de Mesa`/`Michael De Mesa`, `Oz`/`OZ (record producer)`) became two
   nodes. On MediaWiki these are redirects to one canonical title; only the first
   letter is case-insensitive, so a naive canonicaliser cannot fold them.

Fragmentation is corrosive: it splits stigmergic traces across duplicates,
prevents corroboration from aggregating (ADR-3 confidence never sees the second
witness), and degrades every answer. It also compounds the ADR-9 (workspace)
correlated-evidence hazard — duplicates of one source masquerade as independent
witnesses. The open question the card flagged — *where does resolution live?* — is
now answerable from real data, because the two classes have different owners.

## Decision

Adopt **two layers**, by owner:

1. **Connectors normalise their own source's encoding quirks** (the connector,
   and only the connector, knows the source's identity rules). For the MediaWiki
   adapter this is: **URL-decode link targets** before canonicalisation (fixes
   class 1 deterministically and offline), on top of the existing underscore /
   anchor / whitespace / first-letter folding. This layer is *correct by
   construction* for source-specific noise and needs no graph machinery. **Built
   now.**

2. **The kernel gains an alias-resolution seam at the identity boundary** — a
   resolution step consulted by `upsert_node` that maps a `(type, key)` through a
   known-alias / redirect map to a canonical node before minting a new one. The
   map is fed by **source-declared equivalences** first (e.g. MediaWiki redirects,
   resolvable via the API / `prop=redirects`), and later by embedding-candidate
   matching for softer aliases. A merge **preserves provenance and reinforcement**
   (re-point edges, sum `seen_count`, keep the earliest node). This is the general
   fix for class 2 and is the carded follow-up — it is a real seam change and is
   left Proposed here, not built, until its merge semantics are specified.

3. **Resolution is lineage-aware (ADR-9 tie).** A resolved/merged entity must not
   let N derivatives of one origin over-corroborate; the merge keeps distinct
   provenance keys so reinforcement still counts *distinct evidential origins*,
   not duplicate keys.

The split is deliberate: encoding noise is the connector's to remove (cheap,
local, no false merges); semantic identity (aliases, redirects, near-duplicates)
is the kernel's to resolve (it spans connectors and needs the graph + reward).

## Consequences

- **Layer 1 (built).** `canonical_title/1` URL-decodes, closing the percent-encoding
  class; its regression fixture asserts "merged". It removes one well-defined
  encoding class — **not** a complete source-canonicalisation (MediaWiki has further
  rules); it is the cheap, false-merge-free slice.
- **Layer 2 (built).** Two pieces: (a) the connector resolves link targets through
  MediaWiki `normalized` + `redirects` **at ingest, before emit** (`resolve_titles/3`,
  batched ≤50, chained to a fixed point), so a redirect alias and its canonical page
  land on ONE key — this is the blocking-at-ingest form codex asked for, not an
  optional later pass; (b) the kernel `Swarm.Graph.Store.merge_nodes/3` is the
  source-agnostic, **provenance-preserving** reconciler for nodes already fragmented
  (re-point edges, union distinct provenance, recompute `seen_count`, drop
  merge-induced self-loops, rename when the canonical is absent).
- **Proven on real data.** Re-running the live Wikipedia slice (≈1300 article nodes)
  **with resolution on** dropped the fragmentation probe from **4 case-folded
  collision groups to 0** (`Allmusic`/`AllMusic` now one node; the `de/De` name
  pattern collapsed); node count fell 1313→1274 as redirect aliases merged. The
  connector unit tests prove the redirect-collapse and the merge primitive
  (provenance union, no orphan, no self-loop) hermetically.
- **Still future (carded):** a *standing* alias table consulted automatically by
  `upsert_node` for every source (today resolution is MediaWiki-specific in the
  connector, and `merge_nodes` is invoked explicitly, not auto-at-ingest). The
  `de/De`-style folds that are NOT backed by a real redirect remain unresolved —
  surfaced by the probe, not hidden.
- **Merge-induced self-loops are dropped — deliberately (consilium divergence).**
  A second critic (gemini) read this as "losing provenance" and verdict FLAWED;
  codex (and this record) disagree, and the divergence is surfaced here. When the
  alias→canonical edge becomes canonical→canonical, it is a self-referential
  `links_to` artifact, not evidence. Crucially the **source provenance is not
  lost**: the alias page's *real* outbound edges (alias→X) are re-pointed to
  canonical→X carrying that same provenance, so the evidential origin survives on
  the meaningful edges; only the meaningless self-link is dropped. (Were a merge
  ever applied to an edge type where a self-loop is semantically real, this rule
  would need revisiting — for `links_to` it is correct.) The other gemini points
  reduce to the concurrency caveat (already fixed via the `FOR UPDATE` lock, which
  it reviewed pre-fix) and the historical-orphan gap (covered by `merge_nodes` as
  the reconciler + the carded standing-table) — neither blocking.
- **Safety.** URL-decoding a title that legitimately contains a `%` is safe —
  `URI.decode/1` leaves a lone `%` untouched (`"100% (song)"` unchanged), no false
  rewrite. Merges are gated on **source-declared** equivalence (redirects), not
  guessed, so the over-merge hazard is bounded; embedding-candidate (soft) matching
  is deliberately left to the future standing-table work, where a merge rule governs
  it.

## References

- `board/todo/entity-resolution.md` — the follow-up (kernel resolver + redirects).
- `kernel/test/swarm/connector/wikipedia_test.exs` — the two frozen fixtures.
- ADR-4 (graph integrity — shape, not identity); ADR-5 (connector contract);
  ADR-9 workspace (correlated evidence / evidential origin).
