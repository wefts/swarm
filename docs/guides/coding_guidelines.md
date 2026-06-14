# Coding Guidelines

Engineering standards for the swarm **kernel** — this repo. The kernel is two
languages, both in-repo and public (secrets excluded): **Elixir/OTP** (logic,
coordination) and **Python** (ML: embeddings, inference). Plugins/adapters and
corpora live outside the repo (system architecture §13).

Read alongside [`perf_guidelines.md`](perf_guidelines.md) and the `swarm-review`
/ `swarm-check` skills (the operational gates). These guidelines are the "why";
the skills are the "run it now".

## Core principles (language-agnostic)

1. **Functional core.** Pure functions for logic; push side effects (DB, network,
   console) to the edges. Same input, same output.
2. **Immutable data.** Build new structures; never mutate inputs. (Native in
   Elixir; a discipline in Python.)
3. **Typed.** Type every signature. Python: full hints, `ty`/mypy strict.
   Elixir: typespecs (`@spec`) on public functions, Dialyzer clean.
4. **Small modules.** Split by domain; a file you must scroll to understand is
   too big. Target ~250 lines.
5. **KISS.** Simplest thing that works. No speculative abstraction.
6. **DRY at 3.** Extract on the third use; one-offs stay inline.
7. **Fail loud.** Never return a success-shaped value on failure. Errors are
   typed and surfaced; distinguish "empty" from "failed" (ADR-7).
8. **Measured, not tuned.** Thresholds come from data, not feel; the eval/bench
   exists before the feature it measures (ADR-8, perf_guidelines).

## Architecture rules (block on violation)

- **Microkernel.** Kernel code must not import or hardcode a specific connector,
  worker, channel, model provider, or skill. Those are adapters behind ports
  (system architecture §3).
- **Ports are contracts.** Cross-boundary types are Protobuf-defined; the schema
  is the contract.
- **One boundary out.** All external writes go through a single gateway
  (permission, rate-limit, audit, dry-run live there, not at call sites).
  Enforce with an import-lint contract.
- **Clean repo.** No plugins, no corpora (wiki/Confluence/tickets), no secrets in
  the repo. Scratch in `tmp/` (gitignored).

## Elixir / OTP

- **Processes for isolation.** A worker is a supervised process; a crash restarts
  it, it does not take down the swarm (graceful degradation). Let it crash —
  handle the happy path, let the supervisor recover the rest.
- **State in GenServers**, not module globals. Message passing over shared state.
- **Behaviours as ports.** Each port (Connector, Worker, Channel, Model, Tool) is
  a `behaviour`; adapters implement it. The kernel depends on the behaviour, not
  the adapter.
- **Coordination via OTP**: leases/leader/fencing through `Registry`, `:global`,
  `Horde` — not hand-rolled (ADR-1/ADR-2).
- **No blocking the scheduler.** Long/native work goes to a Task/port; never a
  NIF that can crash the BEAM.
- **Typespecs + Dialyzer**; `mix format`; `credo --strict`.

## Python (ML services)

- **uv only.** Never `pip`/bare `python`. Deps in `pyproject.toml`; run via
  `uv run`.
- **Async-first** for I/O; batch model/embedding calls (`gather`), never an
  `await` per item in a loop (perf_guidelines).
- **No module-level singletons / no import-time I/O.** Read config inside
  functions, not at import (breaks `--help`, tests, any bare import).
- **Frozen dataclasses** for config/domain objects; wrap `dict` fields in
  `MappingProxyType` (`frozen=True` only stops rebinding, not mutation).
- **Modern types:** `str | None`, built-in generics, keyword-only bool flags
  (`def f(*, dry_run: bool)`). `dict[str, Any]` only at I/O boundaries.

## Shared discipline

- **Config, not constants.** Thresholds/policies in declarative config (YAML),
  read at function scope. Secrets from env/vault, never committed.
- **Time is tz-aware UTC at the ingestion boundary.** Never stamp naive time as
  UTC. Localize by source tz, convert on entry.
- **Unicode NFC, no lossy ASCII folding** (critical for non-Latin identifiers).
- **Structured LLM I/O** (ADR-7): parse model decisions via structured output /
  token-anchored, never a substring of free text; fence untrusted text; the code
  owns lists/IDs/formatting, the model fills a few fields.
- **No silent failures.** Every dropped item carries a logged reason; log with
  lazy formatting (`%s` in Python, no eager interpolation).

## Naming

| Element | Convention |
| --- | --- |
| Files, scripts, Python funcs, Elixir funcs/atoms | `snake_case` |
| Python classes / Elixir modules | `PascalCase` |
| Constants | `UPPER_SNAKE` (prefer config) |
| Private (Python) | `_prefix` |

## What to avoid

| Don't | Do instead |
| --- | --- |
| Plugin/adapter code inside the kernel | Behind a port, outside the repo |
| Error returned as a success-shaped value | Typed error, raised/returned |
| LLM decision parsed by substring | Structured output / token-anchored |
| Module-level config / import-time I/O | Read inside functions |
| `datetime.now()` (naive) | tz-aware UTC at the boundary |
| `pip` / bare `python` | `uv run` |
| NIF that can crash the BEAM | Task / port / sidecar |
| Hardcoded thresholds | Declarative config |
| `except Exception: pass` | Log + typed fallback |
| Mutating inputs | Return new structures |
| Files that need scrolling to grok | Split by domain |
| Skipping `swarm-check` before commit | Run the gates first |
