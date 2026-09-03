---
status: implemented (storage, write rules, reads); Core.ask exposure and derivation rules open
owner: swarm
---

# Temporal Fact Model

Swarm needs to distinguish facts that describe current state, historical events,
and timeless properties. A single freshness score or TTL cannot express this:
some facts become false when replaced, some remain true as history, and some do
not have a meaningful time axis.

This spec is design only. It does not mandate an immediate schema migration.

## Relation-Level Contract

Temporal behavior belongs to the governed relation registry, beside cardinality,
`subject_kinds`, and `object_kinds`. Extractors do not decide temporal semantics
per fact.

Each governed relation declares one temporal kind:

| Kind | Meaning | Supersession |
| --- | --- | --- |
| `state` | The fact is true for a validity interval, until replaced by a newer state fact for the same governed key. | Superseded by a newer valid-time fact on the same subject, relation, and configured cardinality key. |
| `event` | The fact happened at a time and remains true as history. | Never supersedes a state fact unless a declared derivation rule says so. |
| `invariant` | The fact has no useful validity interval. | Never superseded by time and should not decay for freshness. |

Examples use only synthetic names:

```text
host:a.example.test has_address 192.0.2.10      # state
zone:example.test migrated_to registrar-x       # event
technology:buildkit safer_than privileged-dind  # invariant
```

## Bitemporal Requirement

The graph must keep source truth time separate from ingestion time.

- `valid_time` is the time the source says the fact became true, happened, or was
  last asserted. Supersession uses this value.
- `ingest_time` is when Swarm observed or processed the assertion. It is audit
  history and must not be used as current-state truth when a source time exists.

This prevents late-arriving historical data from overwriting newer state just
because it was ingested later.

## Validity Time Resolution

Ingestors resolve `valid_time` from the strongest source-local timestamp:

| Source shape | Valid-time source |
| --- | --- |
| Live API snapshot | Observation time of the API response, because the API reports current state by construction. |
| Version-controlled infrastructure data | Commit timestamp, or the explicit timestamp in the file when stronger. |
| Ticket or conversation follow-up | Timestamp of the follow-up or message that asserts the fact. |
| Wiki or document page | Page revision time for page-level assertions; embedded explicit dates win for event facts. |
| Undated imported state | Unknown-start sentinel, not ingest time. |

All stored times are UTC. Source-local timezone conversion happens at the
ingestion boundary.

## Undated State Facts

An undated `state` fact is allowed only as an open interval with unknown start.
It must not be treated as "true as of ingest time".

Implementation may represent unknown start as a nullable `valid_from`, a logical
negative infinity, or another explicit sentinel. The required behavior is:

- if it is the only visible state fact, it may answer as current with a clear
  lower confidence or provenance note;
- any later explicitly dated state fact for the same governed key supersedes it;
- an undated fact never supersedes a dated state fact.

## State Supersession Key

A `state` relation declares the key used to close previous intervals. At minimum,
this includes subject and relation. Some relations also need an object class,
environment, address class, or another governed qualifier.

Examples:

```text
host has_private_address address       # same host + relation + private address slot
service hosted_on host                 # same service + relation + environment
person has_status status               # same person + relation
```

The registry must make this explicit. Hidden string conventions are not enough.

## Events Do Not Imply State By Default

An `event` may imply a `state` only through a declared derivation rule. The rule
must name:

- the event relation it consumes;
- the state relation it emits;
- the exact subject/object mapping;
- the `valid_time` assigned to the derived state;
- the supersession key the derived state participates in;
- the evidence requirements and scope behavior.

No extractor may silently turn "X changed to Y" into current state just because
the phrase sounds obvious. The one-of-many and default-with-exceptions failure
class is a temporal failure too: an inference is valid only at the entity level
and condition level supported by the evidence.

## Freshness And Confidence

Freshness decay applies only to relations whose temporal kind permits it.

- `state`: may decay by relation class, but current-state selection must first
  use valid-time intervals.
- `event`: does not decay as history; retrieval may rank recent events higher
  for "recent" questions.
- `invariant`: does not decay.

Confidence should report evidential support and temporal confidence separately
when the distinction matters. A well-supported but stale state fact is not the
same as a weakly supported current one.

## Read Semantics

Readers must distinguish current-state asks from history asks.

- "What is X now?" returns the visible state fact whose validity interval covers
  the query time.
- "What happened to X?" returns event facts and state transitions.
- An unqualified query may use the current-state interpretation for operational
  relations, but should preserve historical context when it appears in the
  grounding.

Scope filtering still happens before temporal selection. A viewer cannot derive
or see a current state from premises they cannot see.

## Implementation Record (2026-09-03, ADR-21 slice 3)

Built with the Proxmox connector, the first source whose answer is a fact at a
known instant. Gemini served as decorrelated critic on the storage shape
(verdict: accept with changes; all adopted, one adapted — see below).

**Where intervals live: a separate `edge_validity` table (schema v13).** Not
columns on `edge` — one fact can be true in several disjoint intervals (a VM
that moves A→B→A), and the natural key plus the corroboration machinery must
stay untouched. Not `edge_provenance` — a provenance row is an observation of
the fact, not of its closure; supersession and closure-by-absence need a row of
their own. Rows partition by the asserting `source` (a site-qualified run
identity such as `proxmox:casa`) so absence reconciliation closes only what
that source asserted, while supersession works on the world-level
`supersession_key` across sources.

Columns: `valid_from` (NULL = unknown start), `valid_to` (NULL = open),
`observed_at` (latest source time the fact was asserted; NULL = undated),
`source`, `origin`, `supersession_key` (denormalised, re-keyed on node merge),
`closed_reason` (`superseded` | `absent` | `manual`), `absent_at` (the run
instant that observed the absence), `recorded_at` / `closed_at` (transaction
time). A GiST exclusion constraint forbids overlapping intervals per
`(edge, source)`; a transactional advisory lock on the supersession key
serialises writers to one logical state. No `superseded_by` pointer —
causality is reconstructed at read time.

Rules as built (`Swarm.Graph.Temporal`): a dated assertion opens or extends an
interval and closes other open intervals on its key (undated ones
unconditionally, dated ones only if they started at or before it); a
late-arriving dated assertion is filed as closed history and never touches
current state; an undated assertion opens an unknown-start interval and closes
nothing. Closure by absence sets `valid_to` to the LAST observation of the
fact, not the run instant (the critic's correction: nothing is asserted true
past the evidence), and keeps the run instant as `absent_at`. Callers gate it on
a complete run. Legacy edges with no interval rows read as undated.

Registry: `Swarm.WorldMap.Domain` declares `temporal` and `supersession`
(`:subject_relation` for single-valued, `:subject_relation_object` for
many-valued) for every governed relation; an undeclared relation fails
compilation. Transport: the connector `Event` gained an optional `valid_time`
(proto3 additive, protocol v1). Reads: `current/3`, `history/3`, `check/4`
resolve subject and object through `alias_of` identity edges.

Deliberately not done here: prose sources (wiki revision time) still emit no
`valid_time`, so a stale page edit cannot flip-flop an authoritative
observation until source-reliability is part of supersession; the dated-vs-
undated selection is per supersession key (per object for many-valued
relations), so a live source that lists members A and B says nothing about a
documented member C — refuting C needs a coverage notion the live source does
not yet declare.

## Open Implementation Questions

- How to expose historical answers through `Core.ask` without overloading the
  existing structured answer shape.
- Which prose-derived relations may carry a page-revision `valid_time`, and
  whether supersession must weigh source reliability once they do.
- A coverage declaration for live sources (`proxmox:SITE` covers
  `net:cluster:SITE contains *`) so an undated documented member the live
  source does not return can be marked unconfirmed rather than merely undated.

## Acceptance For Implementation

Before ingesting temporal sources such as tickets into the graph:

- the relation registry declares temporal kind and supersession key for the
  relations being written;
- undated state facts cannot override dated facts;
- late-arriving historical facts cannot override newer current state;
- event-to-state derivations exist only as declared rules with tests for
  over-broad subject transfer;
- current-state and history queries produce different results on the same test
  fixture.
