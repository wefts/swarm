---
status: proposed
owner: swarm
---

# Structural Spine Vocabulary

This spec defines the governed relation vocabulary Swarm should use to model the
structural spine of the graph: what contains what, where it runs, who operates it,
what depends on it, what kind of thing it is, and what is known to break.

This is not a schema migration and not an accepted ADR. If implementation needs
schema changes, promote the ADR proposal section below through the normal decision
process before code lands.

## Existing Constraints

- Graph nodes keep the existing closed node-type vocabulary in
  `Swarm.Graph.Contract`.
- Edge relation strings are currently format-validated, not globally
  membership-validated.
- `Swarm.WorldMap.Domain` is already the one registry that binds a serve domain to
  cues, entail prompts, corroboration floors, and governed relations.
- The network map already uses a local governed relation set. The structural
  spine generalizes that pattern instead of creating a second vocabulary.
- Every read and served atom remains scope-filtered through the existing
  answer-time policy filter.

## Vocabulary Owner

`Swarm.WorldMap.Domain` remains the vocabulary owner for servable structural
relations. Add a global structural relation registry there, then let domain
entries reference subsets of it.

Shape:

```elixir
%StructuralRelation{
  key: "part_of",
  inverse: "contains",
  subject_kinds: ["entity", "concept"],
  object_kinds: ["entity", "concept", "source"],
  serve_domains: [:network, :who, :structural],
  description: "subject is a component, member, or child part of object"
}
```

The implementation may use maps rather than a struct at first. The important
contract is central ownership: no extractor or read model invents a new relation
without adding it to the registry.

## Core Relations

| Relation | Inverse | Meaning | Serve Use |
| --- | --- | --- | --- |
| `part_of` | `contains` | Subject is a semantic component/member/child of object. | Containment trees, blast-radius roots. |
| `contains` | `part_of` | Subject semantically contains object. | Tree rendering and "what is inside X". |
| `hosted_on` | none | Subject runs on, is deployed to, or is physically/logically hosted by object. | Placement and runtime locality. |
| `operated_by` | none | Subject is run, owned, maintained, or primarily supported by object. | Responsibility and contact routing. |
| `depends_on` | none | Subject requires object for normal operation. | Impact analysis and "what breaks". |
| `instance_of` | none | Subject is an instance/member of a type or class concept. | Typing without expanding `Contract.types/0`. |
| `has_known_issue` | none | Subject has a recurring or documented failure mode. | Known-problem summaries and risk context. |

The current network relations map into this set:

| Current Network Relation | Structural Interpretation |
| --- | --- |
| `contains` | same relation |
| `hosted_on` | same relation |
| `routes_via`, `egresses_via`, `terminates_at`, `protected_by`, `carries` | domain-specific refinements of `depends_on` or `part_of`, retained as network-specific relations while the structural view projects them upward |
| `alias_of` | identity evidence, not a structural relation |
| `has_address`, `has_outbound_ip_address` | attributes, not spine relations |

The structural view may answer from either the exact relation or a registered
projection. Example: `routes_via` can support a dependency answer, but the stored
edge remains `routes_via` so network semantics are not flattened away.

## Directionality

Store the relation in the direction that makes the assertion easiest to read:

- `component part_of system`
- `system contains component`
- `service hosted_on host`
- `service operated_by team`
- `service depends_on database`
- `host instance_of concept:server`
- `service has_known_issue issue-node`

Only `part_of` and `contains` are a formal inverse pair in this spec. Readers may
derive the inverse at query time; writers should not emit both directions unless
the source explicitly states both or the implementation adopts a canonical
inverse-emission rule.

## Identity Bridging Principles

The same real-world referent should converge to one node or one reversible
identity cluster across namespaces.

Rules:

- Strong keys may propose cross-namespace identity: exact IP literals, exact
  FQDNs, canonical service names, stable inventory IDs, and explicit source
  aliases.
- A bridge is allowed only when both sides are visible in the viewer's scopes or
  when the merge is performed under an internal maintenance actor that enforces
  the same no-leak invariant at write time.
- `alias_of` is evidence. It is not itself a merge. Merge remains a governed
  entity-resolution decision with audit/provenance.
- Namespace prefixes such as `net:` prevent accidental collisions; they should
  not prevent a confirmed identity bridge.
- Do-not-merge assertions remain absolute blockers.

Synthetic example:

```text
entity "app.example.test"
net:service:app.example.test
  alias_of app.example.test
```

If confirmed, reads may treat both as one referent; writes still preserve
provenance and scope for each supporting edge.

## Orphan Anchoring

Every extracted entity should be anchored to its evidence and, where the text
states a parent, to that parent entity.

Minimum anchoring:

- `entity extracted_from source-page` or the existing equivalent source
  provenance edge.
- `entity part_of parent-entity` when the source states inclusion, membership, or
  componenthood.
- If no semantic parent is known, anchor to the source page as the temporary
  container so the node is discoverable and explainable.

Synthetic example:

```text
source page: https://docs.example.test/platform/public-addresses
text shape: "Platform A, including CI runners, uses 192.0.2.10."

CI runners extracted_from source-page
CI runners part_of Platform A
CI runners has_outbound_ip_address 192.0.2.10
192.0.2.10 instance_of concept:ip-address
```

The source-page anchor is not semantic containment. It is provenance/discovery
support until the semantic parent is known.

## Issue Modeling

`has_known_issue` points to an issue/failure-mode entity, not free text when the
issue recurs or can be named.

Examples:

```text
service-a.example.test has_known_issue concept:certificate-expiry
service-a.example.test has_known_issue concept:slow-start-after-reboot
```

Incident tickets or runbook snippets may support these edges, but the relation
should describe a known pattern, not a single unexplained failure event. One-off
events remain event/ticket facts unless they recur or are promoted by a source.

## Structural Domain

Add a `:structural` serve domain only after the vocabulary exists in `Domain`.
It should consume the same registry entries as network/who rather than owning a
private list.

Initial cue family:

- containment: "contains", "part of", "inside", Ukrainian equivalents.
- operation: "who runs", "who owns", "operated by", Ukrainian equivalents.
- dependency: "depends on", "what breaks if", "impact", Ukrainian equivalents.
- issues: "known issue", "common problem", Ukrainian equivalents.

The `:network` and `:who` domains should keep their current specialized
relations and project into the structural vocabulary when a structural question
asks for a broader view.

## Conditionality

Conditionality is an open design issue. Some structural facts are only true under
a condition: environment, site, tenant, time window, default/exception row, or
operational mode.

Do not encode conditions by minting relation variants such as
`depends_on_in_prod` or `contains_at_site`. That creates an unbounded vocabulary.

Open options:

1. Reified condition node: `edge applies_under condition-node`.
2. Dedicated edge condition columns.
3. Small condition object attached to edge provenance.

Until an ADR settles this, extraction should prefer conservative omission over a
flat edge that transfers a fact across conditions.

## ADR Proposal: Relation Contract Tightening

If implementation shows discipline is not enough, propose an ADR to make
relation membership contract-enforced.

Candidate change:

- Add `Swarm.WorldMap.Domain.structural_relations/0`.
- Add a graph-contract validation mode for governed relations used by structural
  enrichers.
- Optionally add DB-side defense for the governed subset.
- Keep non-structural experimental edges possible only in an explicitly named
  extension band.

Acceptance evidence for promotion:

- Existing network relations map without data loss.
- Unknown structural relation writes fail loud in tests.
- Scope and provenance behavior remains unchanged.
- No private corpus values are embedded in tests or docs.

## Acceptance for This Spec

- One public design file exists in `swarm/docs/design/`.
- No schema migration, code change, or accepted ADR is created.
- The relation vocabulary covers containment, hosting, operation, dependency,
  typing, and known issues.
- Identity bridging and orphan anchoring rules are explicit.
- Conditionality is named as unresolved rather than hidden in ad hoc relation
  names.
