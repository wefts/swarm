# Decisions (ADRs) — swarm kernel, repo-local

Architecture Decision Records owned by the **`swarm/` kernel repo** — decisions
about kernel internals and coordination that do not bind the whole workspace.
Cross-repo / workspace-binding decisions live in `../../docs/decisions/`, per
`../../docs/standards/how-to-write-adr.md`.

This sequence is **independent** of the workspace ADR sequence: a reference like
"ADR-2 (workspace)" points at `../../docs/decisions/`, while "ADR-1" here is local.

## Index

- [ADR-1: Model Residency Scheduler](0001-model-residency-scheduler.md) —
  Proposed · Complete
- [ADR-2: Stigmergy Signal](0002-stigmergy-signal.md) — Accepted · Complete
- [ADR-3: Confidence Traversal Bounding](0003-confidence-traversal-bounding.md) —
  Proposed · Complete
- [ADR-4: Graph Integrity Contract](0004-graph-integrity-contract.md) —
  Accepted · Complete
- [ADR-5: Connector Ingestion Contract](0005-connector-ingestion-contract.md) —
  Accepted · Complete
- [ADR-6: Answer-Result Algebra](0006-answer-result-algebra.md) —
  Accepted · Complete
- [ADR-7: Self-Model + Asker Identity](0007-self-model-and-identity.md) —
  Accepted · Complete
- [ADR-8: Chat Persona + Off-Topic Deflection](0008-chat-persona-and-deflection.md) —
  Accepted · Complete
- [ADR-9: Backpressure + Poison/DLQ](0009-backpressure-and-dlq.md) —
  Accepted · Complete
- [ADR-10: Trace Lifecycle (decay-driven GC)](0010-trace-lifecycle-gc.md) —
  Accepted · Complete
- [ADR-11: Graph Zones + Claim Typing (N3)](0011-graph-zones-and-claim-typing.md) —
  Accepted · Complete
- [ADR-12: Coordination Control](0012-coordination-control.md) —
  Accepted · Complete
