# Heterogeneous Cognitive Swarm: Reference Architecture

**Architecture class:** *heterogeneous cognitive swarm*: stigmergy through a
shared knowledge graph, with a consilium of large models at the top.

## Abstract

This document specifies a reference architecture for a persistent agentic system
built around the principle of **an intelligent system made from unintelligent
parts**. Many cheap specialized processes run continuously; expensive large
models are used rarely and selectively, which creates a deliberate cost
asymmetry. Coordination is stigmergic: agents leave traces in a shared graph
instead of communicating directly. This aligns with classic blackboard
architecture and Global Workspace Theory.

The architecture is decomposed into 17 domains with strict dependency
direction. Cross-cutting invariants such as concurrency, confidence calculus,
privacy, and provenance are specified as fixed architecture decisions (ADRs).
The document is intended as a general recommendation for projects in this
class. Empirical lessons and open problems are separated into the companion
document.

> One-line principle: cheap specialized processes run all the time; expensive
> large models are rare. Never the reverse.

---

## 0. Cross-Cutting Principles

- **Cost asymmetry:** simple work is cheap and fast; difficult work is expensive
  and rare. Never the reverse.
- **Stigmergy:** agents do not talk directly; they leave traces in the graph and
  other agents react.
- **Everything is a graph node:** users, files, events, concepts, tasks, agents,
  the system itself, and sources.
- **Confidence at every layer:** no claim exists without confidence and source.
- **Graceful degradation:** failure of any component lowers capability, not
  availability.
- **Observability from day one:** if you cannot see why the system did
  something, you cannot debug it.
- **Structural invariants from day one:** production-class systems put
  concurrency, privacy, confidence calculus, and provenance into the kernel
  from the start. Retrofitting them later means rewriting the kernel.
- **Fail loud, no silent failures:** an error never returns as a success-shaped
  value. The system must distinguish "empty result" from "source failed".
  Failures are logged and raised or returned as typed errors the caller must
  branch on. See ADR-7.
- **LLM proposes, code disposes:** the model returns a few structured fields;
  code owns lists, formatting, exact identifiers, and filters. Decisions are
  parsed from structured output or token anchors, never by substring search in
  free text. See ADR-7.
- **Measured, not tuned:** thresholds come from measured distributions, not
  intuition. The eval harness exists before the feature it measures. A quality
  change is accepted only if metrics show it.

---

## Domain 1: Knowledge Graph

The graph is the foundation and shared memory of the swarm.

**Structure:**

- Node schema: `user`, `file`, `event`, `concept`, `task`, `agent`, `self`,
  `source`.
- Edge schema: typed relations such as `modified`, `mentions`, `depends_on`,
  `caused_by`, `relates_to`.
- Edge properties: weight, confidence, creation time, source, TTL, and
  `visibility-scope` (see ADR-5).
- Temporality: edges have time; the graph remembers history, not only current
  state.
- Versioning: ability to roll back and inspect "what was true yesterday".

**Operations:**

- Incremental insert: a new event produces new nodes/edges without a rebuild.
- Traversal engine: graph traversal is the main mode of "thinking".
- Pattern queries: "find all X that lead to Y through Z".
- Edge decay: old edges weaken when not reconfirmed.
- Conflict resolution: two sources disagree; the graph records and resolves it
  by rule, not by silent overwrite.

**Stigmergic reinforcement with decay (ADR-9):**

- A trace has `seen_count` and `last_seen`. Re-detecting the same relation, even
  when phrased differently and matched semantically, reinforces the trace
  instead of duplicating it.
- Reinforcement comes only from provenance-distinct events. `seen_count` grows
  from independent ingest events, not from internal re-detections. Otherwise a
  confirmation loop inflates both strength and "independence" for ADR-3.
- Strength is saturating and decays:
  `strength = f(seen_count) * exp(-lambda * age)`,
  `f(n) = log(1+n) / (log(1+n) + S)`. Linear `f` would create immortal edges.
  Parameters `lambda` and `S` belong in the tuning inventory (ADR-8), not in
  intuition.

**Concurrency (ADR-1):**

- All mutations go through engine transactions. Coordination and claims use CAS
  plus a monotonic fencing token. A write carries the token; stale tokens from
  slow-but-alive holders are rejected.
- Consistency model: eventual only for independent derived data such as tags;
  strong transactional consistency for claim/lease, irreversible actions, and
  consolidation read-modify-write regions.
- Natural key: `(source, type, target, visibility-scope)`. Upsert semantics are
  insert-or-increment, aligned with reinforcement. `seen_count` increments are
  atomic, not lost updates.
- Embedded storage uses WAL, `busy_timeout`, connection-per-task, or a writer
  actor. A shared connection without locks corrupts state.

**Confidence calculus (ADR-3):**

- Each edge carries reliability
  `r_i = r_0 * w_source * exp(-lambda * age)`. Source and time are absorbed at
  the edge before aggregation.
- Chain / AND: `P(path) = product(r_i)`, computed in log-space. Longer
  inference is naturally less reliable; no separate length-decay hack is
  needed.
- Confirmation / OR: paths are partitioned by lineage. Inside a shared-origin
  group, use `max`; across independent groups, use noisy-OR
  `1 - product(1 - P_j)`. This prevents double-counting evidence.
- Product (AND) and noisy-OR (OR) form one coherent algebra. The output is a
  heuristic score until calibrated with isotonic/Platt calibration and ECE
  criteria (ADR-9).

**Visibility and context (ADR-5):**

- Every edge carries `visibility-scope` such as audience, channel, public,
  private, or group. It is materialized as an indexed label or edge type so
  traversal prunes at the index, not by per-edge predicates.
- The graph is single, not per-user. Behavior is context-dependent. Derived
  nodes inherit the narrowest parent scope; widening requires min-support `k`.
  The privacy invariant is default-deny.

**Technical choices:**

- Candidate engines: Neo4j, Memgraph, KuzuDB, or a custom embedded-KV graph.
- Hybrid graph + vectors on nodes: semantic search plus structural traversal.
- Every vector carries an embedding-namespace stamp. Vectors from different
  models are structurally not mixed; cosine thresholds are model-specific.
- Snapshots, backups, partitioning, and archival are required before the graph
  reaches millions of nodes.

---

## Domain 2: Perception / Ingestion

This is how information enters the system.

**Connectors:**

- Filesystem change watchers.
- Git commits, branches, PRs, and blame.
- Wiki/docs systems such as Confluence, Notion, and Markdown.
- Communication channels such as Slack, email, and messengers.
- Calendar.
- System metrics: CPU, processes, logs.
- Third-party APIs.

**Input processing:**

- Normalize many source formats into one internal event format.
- Time is timezone-aware at the ingestion boundary. Each external timestamp is
  localized using the source timezone and converted to UTC on entry. Naive time
  is never stamped as UTC.
- Unicode is normalized without loss. Use NFC; do not fold non-Latin text into
  ASCII. Lossy folding collapses Cyrillic/CJK identifiers and silently loses
  facts.
- Deduplicate events across sources.
- Chunk and parse documents/code.
- Generate embeddings.
- Extract entities and relations for the graph.

**Event-driven, not polling:**

- Durable event queue.
- Throttling and debouncing: 100 file changes per second are not 100 meaningful
  events.
- Input prioritization.
- Backpressure policy when input overloads the system.

---

## Domain 3: Swarm Workers

Workers are cheap, fast, numerous, and parallel. They usually run on local
models such as Ollama.

**Minimal worker set:**

- **Observer:** watches changes and records them; it does not decide.
- **Linker:** builds graph edges between new data and existing state.
- **Classifier:** separates noise from signal.
- **Summarizer:** compresses and summarizes.
- **Tagger:** categorizes and labels.
- **Self-monitor:** checks system health.
- **User-modeler:** updates the user model from signals.
- **Anomaly detector:** detects unusual activity.

**Swarm infrastructure:**

- Worker registry: who exists, what they can do, whether they are alive.
- Scheduler: who runs when.
- Resource pool: parallelism, GPU/CPU limits.
- Lifecycle: spawn, kill, restart hung workers.
- Isolation: one worker crash does not crash others.
- Local model routing and quantization policy.

**Coordination without direct communication (ADR-2):**

- **Level A: partition by worker type.** Observers do not do linker work. Role
  collisions disappear by design.
- **Level B: fenced claim through the graph.** A worker sets `claimed_by`,
  `lease_until`, and a fencing token through CAS. Others see the claim and skip
  the task. Expired leases free the task, but stale-token writes from the old
  holder are rejected.
- **Level C: leader election only for singleton work.** Consolidation/sleep,
  global rebuilds, and re-embedding must run exactly once. They use a fenced
  leader lease, idempotent or fenced work, and a liveness alarm.
- **Scale note:** stochastic ant-colony choice makes sense for thousands of
  agents. With dozens, use an "octopus" pattern: local worker reflexes with
  escalation to the gate.

---

## Domain 4: Consilium

Large models are expensive, slow, and rare: Claude, Gemini, or large local
models.

**Orchestration:**

- Route tasks to models by fit: code, reasoning, synthesis, and so on.
- Call independent models in true parallelism (`gather`), not sequential
  `await` loops.
- Use quorum/voting to synthesize multiple opinions.
- Measure disagreement before synthesis. Capture inter-model variance, such as
  pairwise embedding distance between answers, as a confidence signal before
  the judge collapses opinions into one verdict.
- Fallback chains are fail-loud. If the judge cannot produce a verdict, do not
  pass raw unsynthesized panel text downstream. Drop it or quarantine it with
  low confidence.

**Economics:**

- Token budgets and cost tracking.
- Cache identical requests.
- Compress context before sending it to large models.
- Batch where possible.

**Quality:**

- Structured outputs with schema validation.
- Retry invalid responses.
- Prompt versioning and A/B testing.

---

## Domain 5: Gate / Decision Routing

The gate answers two questions: "Is this hard?" and "Should the system act or
speak at all?"

**Routing gate:**

- Estimate task difficulty.
- Estimate small-agent confidence.
- Decide whether to escalate to the consilium.
- Compare cost and value.

**Correct construction:**

- **Mechanism/policy split.** The matcher returns a raw score, such as cosine
  1-NN to prototypes. Policy, bands, thresholds, and decisions live separately.
- **Bands are empirical (ADR-8).** Handle-confidently, gray-zone-arbitrate, and
  escalate bands come from measured right/wrong score distributions on labeled
  data. They are model-specific and must be rederived when the embedding model
  changes.
- **Verify-then-climb.** Run the cheap path first, then use a post-hoc critic to
  decide whether to climb. The critic is two-stage: deterministic checks first
  (empty output, self-declared inability), then an LLM judge if needed.
- **Confident-wrong is a known hole (ADR-7).** A fluent wrong answer can pass
  deterministic checks. Use a judge from a different model family and measure
  judge accuracy on the handle-confidently band.
- **Bias to escalate under doubt.** A wrong cheap answer is worse than a few
  cents of escalation. Encode this in defaults.
- **Cost telemetry.** Track tier0, tier-tools, escalation counts, and
  percentage handled without cloud models.
- **Graceful degradation.** If embeddings fail, fall back to keyword routing
  with conservative thresholds.

**Action gate:**

- Decide whether to react to an event.
- Decide whether to act now or defer.
- Score importance times moment appropriateness.
- Below the initiative threshold, stay silent and record.

**Interruption model:**

- Speak now for critical events.
- Speak when the user is available.
- Record for later if the user asks.
- Stay silent.
- Detect user state: busy, available, stressed.

---

## Domain 6: Self-Model

The agent is a node in its own graph.

**State to keep:**

- Capabilities and available tools.
- Domain confidence, such as `git: 0.9`, `legal: 0.2`.
- Current load, queues, and resources.
- Known unknowns.
- Error history and error patterns.
- Active tasks and why they are active.

**Healthcheck as self-analysis:**

- Regularly refresh the self node.
- Detect degradation: slower or worse behavior.
- Post-hoc critique of actions.
- Confidence calibration: do "confident" claims come true?

**Construction:**

- **Derived, not stored.** Inventory, freshness, and capability are recomputed
  from sources on demand, not mutated in place.
- **Side-channel measurement stamps.** Expensive/asynchronous metrics such as
  per-domain confidence and eval scores are stamped by separate processes into
  side KV and folded in lazily.
- **Prompt projection.** The self-model provides a short line to the consilium
  system prompt so the model knows what the system knows and does not know.
- **Required core:** calibrated confidence per domain, known unknowns, and
  error history.

---

## Domain 7: User-Model / Theory of Mind

The user model is symmetric to the self-model but scoped per user.

**Model:**

- Current state: busy, stressed, available.
- Communication style: brief or detailed.
- Domain expertise.
- Open questions and unfinished tasks.
- Behavior patterns: active hours and work style.
- Explicit and inferred preferences.
- Trust boundaries: what may be done without asking.

**Dynamics:**

- Update from behavior signals, not only words.
- Support multiple users.
- Preserve privacy between users.

**Topology: one graph, context-dependent behavior (ADR-5).**

There is no separate graph per user. Like a human memory, retrieval is
situational. Each edge/node has `visibility-scope`. The action/communication
gate filters traversal by current context. A private fact exists in the graph
but is not retrieved in a public group chat.

The single graph enables cross-context learning without leaking private
instances. Derived patterns inherit the narrowest parent scope by default;
widening requires min-support `k` from independent sources. Default-deny solves
instance leakage; min-support solves derived-knowledge leakage.

---

## Domain 8: Learning & Consolidation

Learning is built into the architecture from the start.

**Reward signal (ADR-4): external truth first.**

- Objective action results are primary: did code compile, did tests pass, did
  lint pass? This is cheap, real, independent ground truth.
- User correction is a first-class signal: `user_correction` event plus a
  `reward_signal` edge in the schema from day one.
- Internal/self critique is auxiliary and post-hoc, not primary.
- Successful patterns are reinforced from all three sources, with provenance
  controls.

**Consolidation, or "sleep":**

- Compress old events into summaries.
- Discover new relations in accumulated graph state.
- Forget unimportant data through decay.
- Generalize: "this happened five times, so it is a pattern".
- Rebuild and optimize the graph.

**Adaptation:**

- Update domain confidence from experience.
- Adjust gate thresholds.
- Use few-shot examples from the system's own history.

**Gated promotion loop:**

1. **Conservative candidate filter:** only signals converging along genuinely
   independent axes. "Model agrees" and "clean text" are both functions of the
   same model output and count as one axis. Silence from the user is not
   approval.
2. **Dedup + cap per class:** each dropped candidate carries a reason.
3. **Empirical regression gate:** run before/after production metrics on
   externally labeled frozen data plus held-out (ADR-8). Write only on
   non-regression.
4. **Reversible attributed write:** mark writes with `origin:"learned"` and a
   timestamp so the batch can be rolled back.

The circularity guard is mechanical: reject candidates whose confirmation
lineage traces to a previous `origin:"learned"` write. The agent does not
certify itself with its own labels.

---

## Domain 9: Attention & Resource Management

The system has limited attention and must allocate it; it cannot process
everything equally.

- Attention budget.
- Queue prioritization.
- Preemption: a new important task can make an old one wait.
- Emotion-as-prioritization: curiosity/anxiety as signal weight, not human
  emotion.
- Unified resource limits for GPU, RAM, and API budget.
- Degradation under load: what to disable first.
- Feedback-loop stability (ADR-9): reinforcement + retrieval + learning form a
  positive-feedback loop. Damping comes from dominant decay, saturating
  `f(seen_count)`, strength normalization, and reinforcement only from
  provenance-distinct events. Formal stability analysis remains an open
  problem.

---

## Domain 10: Predictive Layer

The system is proactive by nature, not merely reactive.

> Clarification: this is prediction of user needs and world state, not the
> rejected predictive difficulty router in the gate. Difficulty prediction in
> the gate was replaced by verify-then-climb (Domain 5; companion failure #12).

- Hypotheses about the near future: next minute, hour, day.
- Prediction error as a learning signal.
- Domain-specific predictors: deadlines, user work patterns.
- Anticipatory actions: prepare materials before the user asks.

---

## Domain 11: Communication

Only one component speaks to the user, and only with gate permission.

- Response generation adapted to the user model.
- Source citation with confidence.
- Explainability for trust calibration: "I did X because Y".
- Channels: chat, messenger, voice, notifications.
- Message scheduling to avoid spam.
- Confirmation before actions that need it.

---

## Domain 12: Safety / Control / Guardrails

This is what prevents the system from "doing whatever it wants".

- Permission model for autonomous vs confirmed actions.
- Action sandbox for dry execution before real action.
- Dry-run mode.
- Kill switch.
- Full audit log of all actions and reasons.
- Irreversible actions always require confirmation.
- Rate limits to prevent loops.
- Human-in-the-loop thresholds.

**Structural safety:**

- One boundary to the external world. Any external write to a DB, Git,
  messenger, or payment system goes through one gateway object. This gives one
  place for permission, rate limit, audit, and dry-run.
- Dry-run lives in the boundary, not at call sites. A frozen `dry_run` field on
  the gateway short-circuits all mutating methods.
- Single-boundary access is enforced by an import-lint contract, not only code
  review.
- Untrusted-data fencing: external text is data, not instructions. It enters
  prompts fenced as data, and model output is validated before any external
  action.

---

## Domain 13: Observability / Debugging

- Decision traces.
- Graph visualization.
- Swarm metrics: who is working, bottlenecks.
- Logging at every layer.
- Time-travel debugging: reconstruct state at decision time.
- Real-time dashboard.
- Anomaly alerts.

---

## Domain 14: Storage / Data

- Graph storage (Domain 1).
- Vector store for embeddings.
- Relational DB for structured data: users, tasks, logs.
- Blob storage for files, documents, media.
- Event and task queues.
- Cache for fast access and model outputs.
- Backups and recovery for each store.
- Schema migrations.
- Embedding migration (ADR-6): separate from schema migration. Changing the
  embedding model makes old vectors incompatible; use self-healing re-embed
  with namespace stamps, run as a singleton under leader election.
- Concurrent access (ADR-1): embedded storage under many async workers needs
  WAL, `busy_timeout`, connection-per-task, or a writer actor.

---

## Domain 15: Security & Privacy

- Encryption at rest and in transit.
- Data isolation between users.
- Secrets and API keys in a vault.
- Data locality: what never leaves the machine.
- External API policy and PII filtering.
- Access control and authentication.
- Threat model.

**The graph visibility filter is security-critical (ADR-5).**

Privacy is implemented through `visibility-scope` on edges, not physical graph
partitioning. This is powerful, but sharp: a filter bug leaks private data
between contexts/users.

- Default-deny: traversal cannot see an edge unless the context explicitly
  allows it.
- Materialized scope as indexed labels or edge types; index-level pruning avoids
  a scaling wall at millions of nodes.
- Generalization leakage is handled separately: derived patterns inherit the
  narrowest scope and widen only after min-support `k`.
- The filter is enforced in one place, at the gate, not scattered across
  workers.
- Audit all filter decisions and run context-isolation regression tests.

---

## Domain 16: Evaluation / Testing

- Unit tests for workers.
- Swarm integration tests.
- Eval sets to measure whether the system improves.
- Regression tests so new versions are not worse.
- Environment simulation: a test "world" with events.
- Quality metrics: precision/recall, gate false positives.
- Latency and cost benchmarks.

**Statistical rigor (ADR-8/ADR-9):**

- Frozen held-out split (80/20). The regression gate sees only dev-eval; the
  held-out set is reserved for periodic audit against eval overfitting.
- Labels are externally produced and frozen. Otherwise the gate measures model
  self-consistency, not correctness.
- Multiple-comparison correction: per-class regression is K+1 simultaneous
  tests, so use Benjamini-Hochberg/Bonferroni, explicit delta tolerance, and
  minimum sample size.
- Calibration: bootstrap with isotonic/Platt and require ECE below threshold.
  Until then, do not trust confidence; use pass/fail.
- Judge accuracy on the handle-confidently band measures resistance to
  confident-wrong failures.
- Dataset refresh protocol for labeling fresh production outputs and replacing
  stale labels.

---

## Domain 17: Lifecycle / Bootstrapping

- Cold start: how to be useful with an empty graph.
- Onboarding: quickly fill from existing sources.
- Deployment: Docker and process orchestration.
- Declarative, versioned configuration.
- Rolling updates without state loss.
- Data migration between versions.
- Process health monitoring through supervisors.

---

## Prioritization: Where to Start

Not everything at once. The order below produces a working system early.

### Phase 1: Skeleton

1. Knowledge Graph (Domain 1), including ADR-1 transactions/CAS, ADR-3
   confidence calculus, and ADR-5 `visibility-scope` from the start.
2. One or two connectors (Domain 2), such as Git and files.
3. Two or three basic workers (Domain 3), such as observer and linker, with
   ADR-2 claim/lease coordination from the first writing worker.
4. Basic storage (Domain 14), with empty schema slots for `reward_signal` and
   `user_correction` (ADR-4).

### Phase 2: Brain

1. Gate routing (Domain 5).
2. Consilium (Domain 4).
3. Communication (Domain 11).
4. Guardrails (Domain 12).

### Phase 3: Living System

1. Self-model and user-model (Domains 6 and 7).
2. Learning and consolidation (Domain 8).
3. Attention (Domain 9).
4. Predictive layer (Domain 10).

**Throughout:**

- Observability (Domain 13) from day one.
- Security (Domain 15).
- Testing (Domain 16).

---

## Prior Art

No domain is invented from scratch. Each part has mature literature. The novelty
is in the **combination**, not in the individual pieces.

It is important to be precise about novelty. Some subsets of this combination
are already actively studied in 2026:

- **Theater of Mind / Global Workspace Agents** (arXiv
  [2604.08206](https://arxiv.org/abs/2604.08206), April 2026) combines
  blackboard criticism, GWT, specialized parallel processors, and active
  broadcast. It overlaps with Domains 1, 3, 9, and 11.
- **Can Small Agents Collaborate...** (arXiv
  [2601.11327](https://arxiv.org/abs/2601.11327), January 2026) empirically
  supports the base claim that a small specialized multi-agent swarm can
  outperform a larger single model even with direct tool access.

This is not "nobody does this". Rather, pairs and triples of these domains are
appearing in recent work, but the full combination as one persistent personal
system is not commonly found: stigmergic graph + cost-cascade gate +
self/user-model + sleep-like consolidation + predictive layer. Integration is
the contribution.

| Our concept | Known name / field | Primary sources (+ modern examples) |
| --- | --- | --- |
| Shared graph + workers without direct communication (Domains 1, 3) | **Blackboard architecture** | Erman, Hayes-Roth, Lesser, Reddy, "The Hearsay-II Speech-Understanding System", *ACM Computing Surveys* 12(2), 1980; Hayes-Roth, "A blackboard architecture for control", *Artificial Intelligence* 26(3), 1985; modern remakes: [DataFlair](https://data-flair.training/blogs/blackboard-architecture-in-agentic-ai/), [Muthu notes](https://notes.muthu.co/2025/10/collaborative-problem-solving-in-multi-agent-systems-with-the-blackboard-architecture/) |
| Single voice + attention as a resource (Domains 9, 11) | **Global Workspace Theory** | Baars, *A Cognitive Theory of Consciousness*, Cambridge UP, 1988; Dehaene et al. on global workspace neuronal models; modern: [Theater of Mind](https://arxiv.org/abs/2604.08206), [Unified Mind Model](https://arxiv.org/html/2503.03459v2) |
| Stigmergy / pheromone traces (Domains 1, 3) | **Stigmergy / ACO** | Grasse, 1959; Dorigo & Stutzle, *Ant Colony Optimization*, MIT Press, 2004; modern: [Society of HiveMind](https://arxiv.org/pdf/2503.05473), [Agent Swarms + KG](https://atalupadhyay.wordpress.com/2026/03/12/agent-swarms-and-knowledge-graphs-for-autonomous-software-development/) |
| Gate + consilium, cost asymmetry (Domains 4, 5) | **LLM cascades / routing** | [FrugalGPT](https://arxiv.org/abs/2305.05176), [GATEKEEPER](https://arxiv.org/pdf/2502.19335), [UCCI](https://arxiv.org/abs/2605.18796), [routing+cascade](https://openreview.net/forum?id=AAl89VNNy1) |
| "Many small agents > one large model" | Architecture matters more than scale | [Small Agents Collaborate](https://arxiv.org/html/2601.11327v2), [Evolving Orchestration](https://arxiv.org/html/2505.19591v1) |
| Sleep-like consolidation, decay, forgetting (Domain 8) | **ACT-R memory / SOAR** | Anderson et al., ACT-R; [ACT-R memory architecture](https://dl.acm.org/doi/10.1145/3765766.3765803), [Generative Agents reflection](https://arxiv.org/abs/2304.03442) |
| Persistent memory / cognitive architecture for LLM agents (Domains 1, 6, 8) | **MemGPT/Letta, CoALA, Generative Agents** | Packer et al., "MemGPT", [arXiv 2310.08560](https://arxiv.org/abs/2310.08560), 2023; Sumers et al., "Cognitive Architectures for Language Agents (CoALA)", [arXiv 2309.02427](https://arxiv.org/abs/2309.02427), TMLR 2024; Park et al., "Generative Agents", UIST 2023 |
| Self-correction / verify-then-climb / LLM-proposes-code-disposes (Domains 5, 6, ADR-7) | **ReAct / Reflexion / Self-Refine / LLM-Modulo** | Yao et al., "ReAct", ICLR 2023; Shinn et al., "Reflexion", NeurIPS 2023; Madaan et al., "Self-Refine", 2023; Kambhampati et al., "LLM-Modulo Frameworks", ICML 2024 |

**Practical conclusion:** name components using established patterns
(blackboard, GWT, cascade, cognitive architecture) and reuse existing work
instead of rediscovering it.

**Positioning against nearby systems:**

- **MemGPT/Letta:** hierarchical memory with paging, but single-agent and
  without a stigmergic swarm of small workers or cost-cascade consilium.
- **CoALA:** a taxonomy of memory/action/decision that helps organize this
  decomposition; this architecture adds stigmergic coordination and cost
  asymmetry as first-class mechanisms.
- **Generative Agents:** memory stream + reflection, close to consolidation,
  but simulation agents rather than a personal tool with guardrails and privacy.
- **Theater of Mind:** GWT + parallel processors, close to Domains 1/9/11, but
  without self/user models and gated learning.

The novelty claim is the simultaneous presence of all five axes as a persistent
personal system: stigmergic graph, cost-cascade gate, self/user-model,
consolidation, and predictiveness. A systematic feature-by-feature gap table is
outside this design spec and is the next step if the material becomes academic.

Many decisions below come from a previous agent implementation that lacked a
formal architecture but implemented working versions of about half the domains.
Its proven patterns and failures are cataloged in the companion document.

---

## Design Decisions (ADR)

The following decisions are placed in the kernel **from day one** and target a
production-class system. Retrofitting them later means rewriting. Each ADR uses
the shape: decision, rationale, rejected alternatives, where applied.

### ADR-1: Graph Concurrency, Transactions + CAS + Fencing, Mixed Consistency

**Decision:** mutations go through engine transactions. Coordination/claims use
compare-and-swap on node properties with a monotonic fencing token. Strong
consistency is required for claim/lease, irreversible actions, and graph-region
read-modify-write operations such as consolidation. Eventual consistency is
allowed only for independent derived data. Writes are idempotent; the natural
key is `(source, type, target, visibility-scope)`, and upsert means
insert-or-increment. `seen_count` increments are atomic.

**Rationale:** many workers write in parallel, so races are inevitable. Fencing
tokens close the slow-but-alive holder problem. Consolidation is RMW over a
large region; under eventual consistency it clobbers parallel ingest.

**Rejected:** leases without fencing; a global lock over the whole graph.

**Applied in:** Domains 1, 3, 8, and 14.

### ADR-2: Swarm Coordination, Type Partition + Fenced Graph Lease + Singleton Leader

**Decision:** use three layers together: (A) worker-type scope, (B) fenced
claim+lease through the graph for ordinary tasks, and (C) leader election only
for singleton work. Lease renewal is CAS from old `lease_until` to new
`lease_until`; lease duration is much larger than worker p99 latency. Contention
uses randomized backoff and per-worker task-affinity hashing.

**Rationale:** one pattern is not enough. Type partitioning removes role
collisions, graph leases remove duplicate instances without a central boss, and
leader election guarantees sleep/rebuild jobs run once.

**Known edge:** singleton leadership is a scoped SPOF. Therefore the leader
lease is fenced, singleton work is idempotent or fenced, and a liveness alarm
fires if consolidation has not run by time `T`.

**Rejected:** pure ant-colony selection for dozens of agents; a central
orchestrator; a global leader for all work.

**Applied in:** Domains 3, 8, and 13.

### ADR-3: Confidence Calculus, One Probabilistic Frame

**Decision:** use one coherent algebra. Every edge carries reliability
`r_i in (0,1]`, absorbing source and time before aggregation:
`r_i = r_0 * w_source * exp(-lambda * age)`.

- **Conjunction / chain (AND):** `P(path) = product(r_i)`, computed in log-space.
  Product assumes conditional independence of hops (a Markov assumption); for a
  sequential chain this is standard, though positively correlated hops would be
  over-penalized. Lineage correlation is handled on the OR side, not here.
- **Disjunction / confirmation (OR):** partition paths by lineage. Within a
  shared-ancestor group use `max` (collapse correlated paths to their strongest
  representative; `min` would wrongly penalize corroboration); across independent
  groups use noisy-OR `1 - product(1 - P_j)`.

**Rationale:** product and noisy-OR are a coherent pair from one probabilistic
algebra. Mixing possibilistic `min` with probabilistic noisy-OR is incoherent.
Absorbing source and time into `r_i` before aggregation preserves monotonicity.

**Calibration:** output is a heuristic score, not a probability, until
calibrated with isotonic/Platt and ECE criteria. Before calibration, the gate
uses pass/fail decisions rather than confidence.

**Rejected:** min/max possibilistic pair; min+noisy-OR mixture;
Dempster-Shafer, Bayesian nets, and Subjective Logic at this stage.

**Applied in:** Domain 1, Domain 6 calibration, ADR-9, and companion OP #5.

### ADR-4: Reward, External Truth First

**Decision:** the main reward source is objective action outcome
(compile/test/lint) plus user correction as a first-class `user_correction`
event. Self-critique is auxiliary. Schema slots exist from day one.

**Rationale:** the scope is a powerful junior-level tool, not AGI.
Self-generated ground truth without external signal is an open scientific
problem, so the system avoids it and uses cheap objective truth.

**Reference design:** gated promotion loop: conservative candidate filter,
empirical regression gate, reversible attributed write, circularity guard.

**Required enforcement:** circularity guard is mechanical. Candidate filters may
not count correlated signals as independent axes. User silence is not approval.
The provenance check rejects candidates whose confirmation traces to previous
`origin:"learned"` writes.

**Applied in:** Domains 1 and 8, ADR-8.

### ADR-5: Topology, One Graph + Visibility Scope + Derived-Scope Inheritance

**Decision:** use one graph, not a graph per user. Privacy and contextual
behavior are enforced through `visibility-scope` with default-deny. Scope is
materialized as indexed labels or partitioned edge types, not computed as a
per-edge traversal predicate.

**Derived nodes:** a node produced by consolidation from private instances
inherits the narrowest parent scope by default. Widening scope requires
min-support `k` from independent sources.

**Rationale:** this gives brain-like shared memory and situational retrieval
while preventing instance leakage and derived-knowledge leakage.

**Applied in:** Domains 1, 7, 8, and 15.

### ADR-6: Embedding-Namespace Stamp + Self-Healing Migration

**Decision:** every vector carries the stamp of the model that produced it.
Changing the embedding model forces a full re-embed. The stamp is not marked
complete until the run has covered the whole corpus. Cosine thresholds are a
function of the embedding model and must be rederived.

**Rationale:** mixed vectors from different models produce meaningless cosine
scores. Stamps make mixing structurally impossible, and self-healing handles
interrupted migrations.

**Applied in:** Domains 1 and 14.

### ADR-7: LLM I/O Contract, Structured Output + Fencing + Fail-Loud + Verify-Then-Climb

**Decision:** model decisions use structured output or token anchors, never
substring parsing. Code owns lists, formatting, and identifiers. Untrusted
external text enters prompts fenced as data, and outputs are validated before
actions. Failures are fail-loud, never success-shaped. Escalation uses
verify-then-climb.

**Caveats:**

- Shape is not content. Structured output validates form only. Any model field
  that becomes an external-action parameter must be reauthorized against a
  code-owned allowlist.
- Confident-wrong remains a limit of verify-then-climb. Deterministic checks
  catch only self-declared inability; fluent wrong answers need a different
  model-family judge and a measured judge-accuracy metric.

**Applied in:** Principles, Domains 4, 5, 11, 12, and 16.

### ADR-8: Measurement, Empirical Thresholds + Frozen Held-Out + Statistical Rigor

**Decision:** no threshold is hardcoded by intuition. Thresholds are derived
from measured distributions. The eval harness (recall@k, MRR, nDCG, F1,
regression CV) is built before the feature.

- Frozen held-out split: the gate sees dev-eval only; held-out is reserved for
  periodic audit.
- Labels are externally produced and frozen against the learning loop.
- Per-class gates use multiple-comparison correction, explicit delta tolerance,
  and minimum sample size.
- A dataset refresh protocol governs how fresh production outputs are labeled
  and stale labels are replaced.

**Rationale:** without measurement, there is no way to know whether a change
helped. Reusing one eval set in every cycle overfits selection.

**Applied in:** Principles, Domains 5, 8, and 16, plus ADR-9.

### ADR-9: Stigmergic Loop + Calibration, Stability and Saturation

**Decision:**

- Trace strength saturates:
  `strength = f(seen_count) * exp(-lambda * age)`,
  `f(n) = log(1+n) / (log(1+n) + S)`.
- Reinforcement comes only from independent ingest events, not from internal
  re-detections.
- Decay is the dominant pole; parameters `lambda`, `S`, and `mu` live in one
  tuning inventory (ADR-8).
- Cold-start calibration uses isotonic/Platt on 50-200 external labels and
  requires ECE below threshold. Until then, confidence is not trusted.

**Rationale:** positive feedback without saturation and dominant decay
oscillates or runs away. Independent reinforcement is a precondition for ADR-3.

**Rejected:** linear `f`; reinforcement from any re-detection.

**Applied in:** Domains 1, 8, 9, ADR-3, and companion open problems.

---

## Companion Document

Empirical lessons, the failure catalog, and open problems are in
[`failure_modes_and_open_problems.md`](failure_modes_and_open_problems.md). That
document systematizes observed failure classes in LLM-agent systems and the
questions this architecture does not yet fully answer.

---

*Each domain is a separate understandable piece. The system's complexity lives
in their interaction through the graph, not inside the individual parts.*
