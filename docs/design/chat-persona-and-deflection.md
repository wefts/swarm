---
status: built
implements: "swarm ADR-8 (Accepted) — ../decisions/0008-chat-persona-and-deflection.md"
owner: swarm
---

# Spec: Off-topic deflection + skill port (T9, kernel slice)

The kernel-side of the chat surface: off-mission requests are deflected cheaply
(never escalate), and persona/register attaches through the `skill` port — never
in the kernel. The chat channel itself + its copy are a `hive` follow-up.
Implements swarm ADR-8.

## Off-topic deflection (the cost guarantee)

- `Gate.Prototypes` gains an `:off_topic` intent → **tier0**. An off-mission query
  (poem/recipe/weather/joke) routes to the zero-LLM tier0 path.
- `Core.ask` routes tier0 **by intent**: `:off_topic` → `deflect` (a neutral
  steer-back), `:farewell` → `farewell`, else `greeting`. **tier0 never escalates**
  — no consilium, no model call.
- Guarantee asserted: an off-topic query with an injected generator that flags if
  called → `refute_received` (the model is never called).

## The `skill` port (persona, not facts)

`Swarm.Ports.Skill` — `render(answer, context)` phrases the kernel's structured
answer for a context (register, verbosity, language); `deflection(context)` is the
rotating off-topic copy. A skill **skins** facts; it never chooses them (ADR-6 +
presentation-determinism). The kernel's default deflection copy is neutral; the
skill supplies register (DM dry vs public warm/refined), language (uk/fr feminine
self-reference), and rotation.

## Deferred to `hive` (deployment + human review)

The actual **chat channel** (second channel beyond CLI, behind the `channel`
port), carrying asker identity (T8) into Core, and the **persona copy** —
DM-vs-public register, feminine self-reference, the rotating deflection set, the
"who are you really" line — live in `hive/plugins`. The outward-facing public copy
is **human-reviewed** (read by ~1500 strangers). Tracked:
`board/todo/hive-chat-channel`.

## The gate — `test/swarm/core_deflection_test.exs`

| Test | Asserts |
| --- | --- |
| off-topic deflected | tier0, `status: :found`, **no model called** (`refute_received`), steer-back copy |
| tier0 intents distinct | off_topic deflection ≠ greeting |

## Acceptance

- A RECOGNIZED off-topic request deflects with no model call (asserted). A novel
  off-mission request still hits the gate's escalate-under-doubt floor (a real
  question must not be silently deflected) — bounded by ADR-7's budget, tracked as
  a recognition-coverage residual. `mix test` 117/0;
  credo `--strict` clean; dialyzer 0; format clean.
- No persona/register/cost copy in the kernel (only a neutral default + the skill
  port contract).
