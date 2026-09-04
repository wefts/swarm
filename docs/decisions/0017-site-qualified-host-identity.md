# ADR-17: Site-qualified host identity — reconcile by alias, keep the qualifier

Repo-local to `swarm/`. Builds on ADR-13 (entity resolution — two-layer identity,
source-normalisation plus a kernel alias seam) and ADR-4 (graph integrity guards
shape, never identity). Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

**REJECTED — 2026-09-04.** Decorrelated critic returned FLAWED. Not accepted, not
built, and **no alias has been written to any graph**. The implementation drafted
against it (`Swarm.Graph.HostIdentity` and its tests) was reverted rather than left
in the tree: a module implementing a rejected decision invites someone to run it.

The problem this ADR names is real and still open. The decision it proposed is not
the fix. Superseding work is carded at
`board/todo/host-identity-reconciliation-lifecycle.md`.

## Why it was rejected

### 1. The evidence was circular — the disqualifying one

The ADR argued from *"159 of 159 names resolve to exactly one site, 0 collisions"*.
That measures **how often the name-equality rule applies**, not whether it is
**correct**, because those 159 identities were *selected by that same name
equality*. A tautology dressed as a validation — and the third time in this
campaign a population described by the rule under test was read as support for it.

Nothing independent was consulted: no IP, no UUID, no IaC reference, no source
declaration, no sampled human check. ADR-13 reserves aliases for **known or
source-declared** equivalence; this substituted lexical coincidence.

The counterexample that kills it is **name reuse across time**. A wiki fact about
`db01` may describe a machine retired two years ago. The rule attaches it,
confidently, to today's `db01` — and the result looks exactly like two sources
corroborating each other.

### 2. The collision branch was called a future guard. It is not

Milestone 6 had *already* found `Gitlab` and `Nextcloud` resolving to hosts at two
sites. Calling ambiguity hypothetical was contradicted by this campaign's own
record from the day before.

And the rule was write-time only: it declines to write on ambiguity, and says
nothing about an alias that was valid yesterday and becomes ambiguous when a new
site appears or a hostname is recycled. There is no revocation path.

### 3. The 2.4% result gives no evidence for the alias basis

`learner_eval_link_evidence.decide/2` has **no alias branch** — all 15 licensed
links are `title_equality`, so the analyzer never exercised ADR-17 at all and the
document/host measurement is silent about it. Only **2 of 19** frozen join subjects
have even a licensed title link. On the evidence actually gathered, this is not the
next join fix.

### 4. A mutable site label is not durable canonical identity

The ADR made `net:host:<site>/<name>` canonical with no immutable site id and no
rename or merge behaviour. Renaming a site creates a new keyspace: it breaks
temporal continuity for every fact under the old label and orphans every alias
pointing into it.

## What survives

- The **problem statement** in the Context below, unchanged and still measured: 159
  machines under two graph keys, 0 aliases, 0 edges between them, and no Proxmox
  edge corroborated by documentation about the same machine
  (`board/todo/proxmox-identity-not-reconciled.md`).
- One constraint learned while building the rejected version: `Store.upsert_node/3`
  consults the alias table *before minting*, so an alias changes only where the
  **next** write lands. A real fix must converge the nodes and edges that already
  exist — redirection alone leaves the split it was meant to heal.

## What a correct decision must establish

1. **Equivalence from something other than the name** — an IP, a UUID, an IaC
   declaration, a source assertion, or sampled human confirmation — with a measured
   error rate on a sample the rule did *not* select.
2. **Convergence, not redirection.** Existing nodes and edges must end on one
   subject.
3. **A lifecycle.** Aliases revocable and remappable, atomically, when uniqueness
   changes: a new site, a recycled hostname, a rename.
4. **Durable identity.** An immutable site identifier with defined rename and merge
   behaviour, before any key shape is called canonical.
5. **Scope safety throughout.** The two keys sit in different `src:` scopes;
   reconciliation must never widen visibility.

## Record Completeness

Complete as a rejected proposal. The Context below is retained because the problem
it documents is still open; the Decision and Consequences are retained so the wrong
turn stays legible, and are **not** to be implemented.

## Context

Two components mint identities for the same machines and neither knows about the
other.

The Proxmox connector site-qualifies every subject on purpose, so that a `web-01`
in one datacentre never merges with a `web-01` in another:
`net:host:<site>/<name>`. The network map, built earlier from wiki prose and IaC
repositories, uses the unqualified `net:host:<name>`.

Counted on staging, 2026-09-04:

| count | what |
| --- | --- |
| 754 | `net:host:<site>/<name>` nodes, all in the proxmox source scope |
| 359 | `net:host:<name>` nodes from the network map, other scopes |
| **159** | machines existing under **both** keys — galaxy 151/162, forge 8/592 |
| **0** | `node_alias` rows linking the two shapes |
| **0** | edges between a `net:host:%` node and any document-derived entity |
| 1508 | edges touching a Proxmox host node — every one origin-family `proxmox` |

Consequences of the split, all observed:

1. **Corroboration cannot fire.** ADR-13 supersession compares claims about the
   *same subject*; to the graph these are different subjects.
2. **It corrupts subject binding.** The tier-gate's candidate binding had to group
   candidates by stem and prefer the site-qualified key — a read-layer workaround
   for a write-layer defect.
3. **It is invisible.** It was found by counting, after a measurement had already
   been distorted by it.

## Decision (rejected — retained for the record, not to be implemented)

Reconcile with `node_alias` rows, site-qualified key canonical, written only where
the unqualified name resolves to exactly one site; refuse otherwise. Rejected for
the four reasons above — principally that name equality is not evidence of
identity.
