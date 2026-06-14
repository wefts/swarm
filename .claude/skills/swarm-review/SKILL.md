---
name: swarm-review
description: >
  Review a diff, file, or PR against the swarm project's architecture rules
  (microkernel boundaries, the ADR invariants, fail-loud, clean-repo). Use when
  the user says "review", "code review", "look over this", "is this ok to merge".
  One line per finding, severity-tagged, no praise padding.
---

# swarm-review

Review against this project's locked decisions. Output one line per finding:
`path:line: SEVERITY: problem. fix.` (CRIT/HIGH/MED/LOW). No praise. Skip
nits that do not change meaning. Read `docs/swarm_architecture_spec.md` and
`docs/system_architecture.md` if context is needed.

## Architecture boundaries (block on violation)

- **Microkernel.** Kernel code must not import or embed a specific connector,
  worker, channel, model provider, or skill. Those are adapters behind ports.
- **Clean repo / plugins outside.** No plugin/adapter code, no test corpora
  (wiki/Confluence/tickets), no secrets in the repo. Plugins and data live
  outside the repo, reached via config paths (see system architecture §13).
- **One boundary.** All external writes go through the single gateway; no direct
  external calls scattered in code. Enforced by import-lint contract.

## ADR invariants (block on violation)

- **Fail loud** (ADR-7): errors are typed and raised/returned, never a
  success-shaped placeholder string. Distinguish "empty" from "failed".
- **LLM I/O** (ADR-7): decisions parsed via structured output / token-anchored,
  never substring of free text. Untrusted external text is fenced in prompts;
  model-supplied action targets are re-authorized against a code-owned allowlist.
- **Concurrency** (ADR-1): graph mutations are transactional; claim/lease uses
  CAS + monotonic fencing token; consolidation is idempotent/fenced.
- **Confidence** (ADR-3): one probabilistic frame — product along chain, `max`
  within a shared-ancestor group, noisy-OR across independent groups. No
  possibilistic `min` mixed with noisy-OR.
- **Privacy** (ADR-5): visibility-scope default-deny; derived nodes inherit the
  narrowest parent scope, widen only on min-support.
- **Embeddings** (ADR-6): vectors carry a model stamp; no mixed-model vectors.

## Hygiene

- Time is tz-aware UTC at the ingestion boundary; no naive timestamp stamped UTC.
- Unicode normalized (NFC) without lossy ASCII folding.
- Shell scripts and filenames are snake_case.
- No silent failures anywhere; every dropped item carries a logged reason.
- Config read at function scope, not import time; secrets from env/vault.

End with a one-line verdict: block / approve-with-fixes / approve.
