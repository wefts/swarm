---
status: proposed
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

## Open Implementation Questions

- Whether temporal intervals live on `edge`, `edge_provenance`, or a separate
  fact assertion table.
- How to expose historical answers through `Core.ask` without overloading the
  existing structured answer shape.
- Which existing relations should be classified first. Network address and
  route relations are the highest-value `state` candidates; document-kind and
  technology property relations are likely `invariant`; migration and incident
  records are `event`.

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
