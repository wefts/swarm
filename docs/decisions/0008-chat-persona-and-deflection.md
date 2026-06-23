# ADR-8: Off-topic deflection (cheap) + persona via the skill port

Repo-local to `swarm/`. Cross-references to "ADR-N (workspace)" point at
`../../../docs/decisions/`.

## Status

Accepted (kernel slice built and validated — see
`../design/chat-persona-and-deflection.md`). The chat channel + persona copy are a
`hive` deployment follow-up.

## Record Completeness

Complete

## Context

glpi-agent's real surface was a chat bot, and that is where the edge-scars showed:
off-topic generation burned tokens (a poem/recipe = a wasted escalation), register
had to depend on channel (DM dry/sharp vs public warm/refined — public is read by
~1500 strangers), feminine self-reference (uk/fr grammatical gender), asker
identity, not-found UX. A CLI never exercises these. The kernel is right to stay
neutral; persona / cost / register are a **channel + skill** concern.

## Decision

1. **Recognized off-topic deflects free.** An off-mission request that matches the
   `:off_topic` tier0 intent (`Gate.Prototypes`) is answered on the **zero-LLM**
   tier0 path — it does **not** escalate; a recognized poem/recipe cannot burn a
   model call. **Honest boundary:** recognition is similarity to the prototype
   exemplars, not a structural floor. A *novel* off-mission request (semantically
   far from the exemplars) falls to the gate's **deliberate escalate-under-doubt
   floor** and still costs a model call — because an unknown query may be a *real*
   question, and deflecting all low-confidence input would drop real questions
   (the worse failure). So this **mitigates** the off-topic cost scar for the
   recognized set; it does not close it for arbitrary input. Widening recognition
   (more exemplars / a learned off-topic classifier) shrinks the residual; ADR-7's
   per-escalation budget bounds the cost when an unrecognized one does escalate.
   The kernel returns a neutral steer-back; the *copy* is not the kernel's.

2. **Persona/register/language live behind the `skill` port.** `Swarm.Ports.Skill`
   is the contract a channel attaches: `render/2` (phrase the kernel's structured
   answer for a context — register, verbosity, language) and `deflection/1` (the
   rotating off-topic copy for the context). A skill **skins** the facts; it never
   decides them (ADR-6 + the presentation-determinism standard). Persona is
   **never kernel code**.

3. **The chat channel + persona copy are a `hive` deployment.** The second channel
   (beyond CLI) — DM-vs-public register, feminine self-reference, the rotating
   deflection set, the "who are you really" line — lives in `hive/plugins` behind
   the `channel`/`skill` ports, with the **outward-facing public copy
   human-reviewed** (it is read at scale). Tracked: `board/todo/hive-chat-channel`.

## Consequences

- The off-topic→escalation scar is **mitigated** at tier0 for the recognized set
  (asserted: a recognized off-topic does not call a model), and **bounded** by
  ADR-7's budget when an unrecognized one escapes to escalation — not "closed by
  construction". Closing it further is a recognition-coverage problem, tracked as
  a residual, not claimed done.
- Persona/register/language are out of the kernel — a localized or context-styled
  surface composes from the structured facts (ADR-6) via a skill, so the kernel
  carries no English-prose or register assumptions beyond a neutral default.
- The kernel slice (deflection mechanism + skill port) is testable now; the chat
  channel and its public copy are a deployment + human-review task, honestly
  deferred to `hive`.

## Alternatives

- **Generate deflections with a model.** Rejected — burns a model call on an
  off-mission request, the exact scar; tier0 canned is the cost guarantee.
- **Put persona/register in the kernel.** Rejected — couples the kernel to
  register, language, and grammatical gender; the kernel stays the single voice of
  *facts*, a skill is the voice of *style*.
- **One register for all surfaces.** Rejected — a public surface read by ~1500
  strangers needs a different register than a DM; register is context-dependent,
  selected by the channel.
- **Deflect ALL low-confidence input to make off-topic free by construction.**
  Rejected — the escalate-under-doubt floor exists because an unknown query is
  often a *real* question; deflecting all of it would refuse real questions (a
  worse failure than the cost). Off-topic stays recognition-based; the residual
  cost is bounded by ADR-7's budget, not by silencing the unknown.
