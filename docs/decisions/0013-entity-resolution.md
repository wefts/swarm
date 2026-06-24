# ADR-13: Entity resolution — two-layer identity, source-normalisation now + a kernel alias seam

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`. Builds on ADR-4 (graph integrity — guards SHAPE) and
ADR-9 (workspace, correlated-evidence) and is grounded in the first live slice
(Phase E2, Wikipedia).

## Status

Proposed (first increment built — connector source-normalisation; the kernel alias
resolver is the carded follow-up `board/todo/entity-resolution`)

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

- **Now:** the percent-encoding fragmentation class is closed; its regression
  fixture flips to "merged". The connector stays a reference adapter; the fix is a
  pure function (`canonical_title/1` URL-decodes), still hermetic and tested.
  Layer 1 removes one well-defined encoding class — it is **not** a complete
  source-canonicalisation (MediaWiki has further normalisation rules); it is the
  cheap, false-merge-free slice of the problem, not the whole of it.
- **Deferred (carded):** the kernel alias resolver + MediaWiki redirect resolution
  for class 2. Until it lands, the case/redirect fixtures remain KNOWN-GAP and the
  slice's fragmentation probe still reports the case groups — honestly surfaced,
  not hidden.
- **Interim risk (consilium, codex):** deferral is *not* free. Until layer 2 lands
  the graph is **knowingly fragmented** for class 2 — corroboration splits across
  the duplicate nodes (ADR-3 never sees the second witness) and any answer built on
  that evidence is degraded. This is a stated, bounded debt, not a silent one; it
  must not be read as "entity resolution is done". Accordingly, layer 2's
  implementation card specifies the alias/merge as a **blocking ingest invariant
  for sources that declare redirects**, with **provenance-preserving de-duplication**
  (re-point edges, union distinct provenance, sum `seen_count`), not an optional
  pass.
- **Safety:** URL-decoding a title that legitimately contains a `%` is safe —
  `URI.decode/1` leaves a lone `%` untouched (`"100% (song)"` is unchanged), so no
  false rewrite. Over-eager kernel merging is the real hazard and is exactly why
  layer 2 is gated behind a specified merge rule, not shipped reflexively.

## References

- `board/todo/entity-resolution.md` — the follow-up (kernel resolver + redirects).
- `kernel/test/swarm/connector/wikipedia_test.exs` — the two frozen fixtures.
- ADR-4 (graph integrity — shape, not identity); ADR-5 (connector contract);
  ADR-9 workspace (correlated evidence / evidential origin).
