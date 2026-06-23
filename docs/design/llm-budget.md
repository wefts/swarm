---
status: built
implements: "ADR-7 workspace (budget dimension) — ../../../docs/decisions/0007-llm-io.md"
owner: swarm
---

# Spec: LLM per-escalation budget (T5)

How the kernel puts a hard cost ceiling on a model escalation, so a raw tool/source
payload can never be shipped to a model (the glpi-agent 385k-token scar). Realizes
the budget dimension of ADR-7 (workspace).

## Mechanism — `Swarm.LLM.Budget`

- `estimate_tokens(text)` — bytes ÷ 4. A cheap, deliberately *conservative*
  (slightly high for multibyte) proxy, not a tokenizer; the safe direction for a
  ceiling is to over-estimate.
- `ensure(prompt, ceiling)` — `:ok` if within, else
  `{:error, {:over_budget, estimated, ceiling}}`. **Refuse fail-loud; never
  truncate.**
- `account(tokens_in, tokens_out, meta)` — emits `[:swarm, :llm, :escalation]`
  telemetry; the caller computes the totals (so panel fan-out is counted), `meta`
  carries `outcome: :ok | :over_budget`.

## Enforcement — two layers

**Global backstop — `Swarm.ML.Generation.generate/3`.** The hard per-call ceiling
(`Swarm.Config.max_prompt_tokens/0`, default `64_000`) is checked at the model
boundary itself, before the gRPC ship-out. *Any* caller — consilium, a future
channel, a tool adapter — is refused fail-loud above it, so no model call can
exceed the ceiling. This is the structural guarantee.

**Tighter early check — `Swarm.Consilium.deliberate/2`**

The ceiling comes from config (`:consilium, :token_ceiling`, default `32_000`) or
a `:token_ceiling` opt. Before any model call:

1. build the panel prompt → `Budget.ensure` → refuse if over;
2. run the panel (only reached if within budget);
3. build the judge prompt → `Budget.ensure` → refuse if over;
4. judge → on success, `Budget.account(judge_prompt, answer)`.

Because the check precedes the `Task.async_stream` panel call, an over-ceiling
escalation **never invokes a model** — and even if a caller skipped the consilium,
the boundary backstop still refuses. Accounting covers the **whole** escalation
(N × panel prompt + judge in; all takes + judge answer out), and a **refusal**
also emits telemetry (`outcome: :over_budget`) — the security-relevant event.

## Invariants (ADR-7 budget)

- **Hard per-escalation ceiling** — config-driven, refuse-not-truncate.
- **Ground-before-model** — the kernel rejects an ungrounded payload; producing a
  bounded grounded context is the caller's job (where the source/tool context is).
- **Cost is observable** — per-escalation tokens in/out in telemetry.

## The gate — `test/swarm/llm/budget_test.exs`

| Test | Asserts |
| --- | --- |
| estimate / ensure | bytes/4; within → `:ok`; over → `{:error, {:over_budget, est, ceiling}}` |
| huge grounding refused | a 600k-byte grounding → `{:error, {:over_budget, …}}` AND the injected generator is **never called** (the 385k path is structurally impossible) |
| within budget | escalates, returns the verdict, and emits `[:swarm, :llm, :escalation]` cost telemetry |
| boundary backstop | `Generation.generate/3` with a >64k prompt → `{:error, {:over_budget, …}}` before any RPC (no ML service needed) — proves ANY caller is bounded |

## Limitations (honest scope)

- **Estimate, not a tokenizer.** bytes/4 can *under-count* adversarial input
  (whitespace/punctuation) and non-Latin scripts (CJK ≈ 3 bytes but ~1 token/char).
  It is ample against a catastrophic dump (the 385k scar is ~12× the 32k ceiling —
  margin swamps the error) but approximate near the boundary; a real tokenizer
  would tighten it.
- **Per-call, not per-turn.** The ceiling bounds one prompt; an N-model panel
  spends ≈ N × ceiling + judge per escalation. Total is bounded by panel-width ×
  ceiling and is what telemetry reports — but a wide panel is still N× a single
  call. Hierarchical token buckets / circuit breakers (a turn-level budget) are a
  later extension, not built here.
- **Refuse, not auto-compress.** The kernel does not summarize an over-budget
  payload (that would need a model call / digest); it refuses and forces grounding
  upstream.

## Acceptance

- `mix test` 100/0; credo `--strict` clean; dialyzer 0; format clean.
- ADR-7's budget dimension is no longer a forward-reference.
