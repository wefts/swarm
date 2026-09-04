# ADR-17: Site-qualified host identity — reconcile by alias, keep the qualifier

Repo-local to `swarm/`. Builds on ADR-13 (entity resolution — two-layer identity,
source-normalisation plus a kernel alias seam) and ADR-4 (graph integrity guards
shape, never identity). Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Proposed — decided from measurement, not yet reviewed by a decorrelated critic.

## Record Completeness

Complete for the decision; the migration's exact batching is left to the build.

## Context

Two components mint identities for the same machines and neither knows about the
other.

The Proxmox connector site-qualifies every subject on purpose, so that a `web-01`
in one datacentre never merges with a `web-01` in another:
`net:host:<site>/<name>`. That is correct and is the more precise identity. The
network map, built earlier from wiki prose and IaC repositories, uses the
unqualified `net:host:<name>`.

Counted on staging, 2026-09-04 (`board/todo/proxmox-identity-not-reconciled.md`):

| count | what |
| --- | --- |
| 754 | `net:host:<site>/<name>` nodes, all in the proxmox source scope |
| 359 | `net:host:<name>` nodes from the network map, other scopes |
| **159** | machines existing under **both** keys — galaxy 151/162, forge 8/592 |
| **0** | `node_alias` rows linking the two shapes |
| **0** | edges between a `net:host:%` node and any document-derived entity |
| 1508 | edges touching a Proxmox host node — every one origin-family `proxmox` |

Three consequences, all observed rather than predicted:

1. **Corroboration cannot fire.** ADR-13 supersession compares claims about the
   *same subject*. To the graph these are different subjects, so not one of the
   1508 Proxmox edges is corroborated by the wiki or IaC facts about the same
   machine.
2. **It corrupts subject binding.** The tier-gate's candidate binding had to grow
   a special case: when the question named `netserv`, both keys matched and the
   gate declared the ask ambiguous, refusing an answer that had exactly one real
   subject. The current mitigation groups candidates by stem and prefers the
   site-qualified key — a workaround at the read layer for a defect in the write
   layer.
3. **It is invisible.** Nothing surfaces it. It was found by counting, after a
   measurement had already been distorted by it.

## Decision

**Reconcile with alias rows, and keep the site qualifier as canonical.**

- `node_alias(type, alias_key, canonical_key)` gains a row per reconciled machine:
  `alias_key = net:host:<name>`, `canonical_key = net:host:<site>/<name>`. The
  seam ADR-13 already built is the right one; it has simply never been used for
  this.
- **The site-qualified key is canonical, always.** It carries strictly more
  identity. The unqualified key is the alias, never the target.
- **Refuse the ambiguous ones rather than guess.** A row is written only when the
  unqualified name resolves to exactly one site. Where a name exists at two sites,
  no alias is written and the ambiguity is recorded for an operator decision. A
  wrong merge here silently fuses two machines; a missing alias merely leaves
  today's behaviour.

  Measured on staging 2026-09-04: of the **159** network-map names that match a
  Proxmox host, **159 resolve to exactly one site and 0 are ambiguous**. So the
  exact rule covers the whole current population and the refuse branch is empty
  today. It is kept as a guard, not as an expected path — `forge` and `galaxy`
  happen to use disjoint naming conventions, and a third site need not.
- **Reconciliation is a pass, not an ingest-time coupling.** The connector keeps
  emitting exactly what it observes. Nothing about site qualification changes.

### Alternatives, and why not

- **Entity-resolution `same_as` proposals (ADR-13 layer 2).** The heavier
  machinery — polysemy guards, scope guards, an LLM confirm — earns its cost when
  identity is *uncertain*. Here it is not: an exact stem match against a
  single-site name is deterministic. Reserve ER for the cases the exact rule
  refuses.
- **Qualify the network map at ingest.** The best identity and the largest change,
  and it needs a site attribution the wiki prose often does not carry. It would
  also rewrite history for facts already asserted. Revisit if the wiki gains
  reliable site attribution.
- **Do nothing and let the read layer cope.** Rejected: the binding workaround is
  already a read-layer patch for a write-layer defect, and every future reader
  would need the same patch. That is how a defect becomes an idiom.

## Consequences

- Corroboration becomes possible for 159 machines: wiki/IaC claims and Proxmox
  observations land on one subject and ADR-13 supersession applies. Expect some
  contradictions to surface immediately — that is the point, and they will need
  the authority contract (`board/doing/placement-retrace.md`, step 4) to resolve:
  an observation from the hypervisor outranks a documented claim *about placement*,
  and does not outrank documentation about purpose.
- Cross-source scope: the two keys sit in different `src:` scopes, so an alias
  spans them. Aliasing must not widen visibility — resolution happens before the
  scope predicate, never instead of it, and the ADR-18 (workspace) F3 clamp stands.
- The binding workaround in `Coverage` stays. It is independently correct: two keys
  for one machine is not the only way a question can name one subject twice, and
  the read layer should be robust to it whether or not the write layer is clean.
- Reversible: deleting the alias rows restores today's behaviour exactly. No node
  is merged, no edge is rewritten.

## What must be true before this is Accepted

1. A decorrelated critic reviews it — specifically the claim that exact stem match
   against a single-site name is safe enough to skip ER.
2. ~~The ambiguous set is counted.~~ **Done** — 159 of 159 unambiguous, 0 collisions
   (query in `board/todo/proxmox-identity-not-reconciled.md`). The refuse branch is
   a guard against future sites, not the common path.
