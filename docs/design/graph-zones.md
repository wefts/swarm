---
status: built
implements: "swarm ADR-11 (Accepted) — ../decisions/0011-graph-zones-and-claim-typing.md"
owner: swarm
---

# Spec: Graph zones + claim typing + reward-gated persistence (T12, N3)

The structural defense against graph error-cascade. Implements swarm ADR-11;
extends the ADR-4 contract (schema version 2).

## Zones — `node.kind`

A closed vocabulary (contract `Contract.kinds/0` + DB `CHECK node_kind_vocab`):
`observation` (external evidence, default), `claim` (LLM-generated), `hypothesis`,
`coordination`, `lease`, `derived`, `presentation`, `durable_fact`. Each kind is a
lifecycle class — the hook for per-zone TTL/compaction (composes with T11 GC).

## Claim ≠ independent — `Confidence.combine_typed/1`

Input `[{confidence, kind}]`. All LLM-generated kinds (`claim`/`hypothesis`/`derived`) collapse to **one** group
(max within); each non-claim is its own independent group (noisy-OR across). So:

- `[{0.8,"claim"}, {0.8,"claim"}, {0.8,"claim"}]` → `0.8` (one group, not inflated)
- `[{0.8,"observation"}, {0.8,"observation"}]` → `0.96` (independent corroboration)

A hallucination cannot raise confidence by being repeated across models. **Now LIVE (workspace
ADR-13 / EOS-2, 2026-06-25):** `combine_typed/1` was a zero-caller pure function until the
evidential-origin epic wired it into the read path via node-local `Swarm.Graph.Corroboration`
(structural edges excluded; **origin-dedup before** the combine), paired with the strength-side
per-origin reinforcement ceiling (`seen_count = count(distinct origin)`). The guarantee above is
now live behavior, verified, in both dimensions. (Lineage-aware clustering of semantically-
correlated *distinct* origins is the deferred next cut — ADR-13.)

## Reward-gated persistence — `edge.reward` + `Store.set_reward/2`

External ground-truth reward on a trace. `set_reward(edge_id, r)`: `r < 0`
**refutes** → it is excluded from `Swarm.Graph.Traverse` at READ time
(`… AND e.reward >= 0`) immediately, and `Swarm.Graph.GC.reap/1` then deletes it
regardless of strength (WHERE `reward < 0 OR decayed_strength < floor`). A refuted
trace stops being ground the instant it is refuted, not only after the next GC.

## The gate — `test/swarm/graph/zones_test.exs`

| Test | Asserts |
| --- | --- |
| claim independence | 3 claims → 0.8 (one group); 2 observations → 0.96 (independent) |
| typed distinctly | observation vs claim node `kind` persists |
| unknown kind rejected | `kind: "bogus"` → changeset invalid |
| reward-gated reap | a refuted (reward −1) fresh edge is reaped, the good one kept |
| refuted not traversable | a refuted edge is excluded from `traverse` immediately (before GC) |
| any generated kind | claim/hypothesis/derived all collapse to one group |
| v1→v2 round-trip | a node written without `kind` reads back `observation` |
| schema version | stamped + compiled version == 2 |

## Limitations (honest scope)

- **Per-kind TTL/compaction policy is the hook, not yet differentiated** — the
  `kind` field + GC make it expressible; distinct per-kind TTLs are a follow-up
  (T11 GC currently uses one global decay floor).
- **Reward source is the caller** — `set_reward` is the coupling; who computes the
  external reward (the reward path, ADR-4 workspace) feeds it. Edge-level reward
  only; node-level reward is not modeled here.

## Acceptance

- Claim-not-independent + reward-gated reap proven; schema v2 round-trip tested.
  `mix test` 136/0; credo `--strict` clean; dialyzer 0.
