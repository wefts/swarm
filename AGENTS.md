# AGENTS.md — Swarm Kernel Repo

This is the **Swarm** product repo: the public kernel/control-plane for the
local-first heterogeneous cognitive system.

Read the workspace guide first: `../AGENTS.md`. Shared architecture, standards,
and current state live in `../docs/`; repo-specific implementation detail lives
here.

## What This Repo Owns

- Protobuf contracts in `proto/`.
- Elixir/OTP kernel in `kernel/`.
- Python ML service in `ml/`.
- Python CLI channel in `cli/`.
- Generic stateful infra in `infra/`.
- Kernel-specific architecture and engineering docs in `docs/`.

This repo does **not** own concrete plugins, private corpora, private env files,
or secrets. Those belong outside the public kernel, normally in sibling `../hive`.

## Read First

- `README.md` — product overview, layout, toolchain, development commands.
- `docs/system_architecture.md` — kernel/plugin boundary, tech stack, deployment.
- `docs/swarm_architecture_spec.md` — cognitive architecture and older ADR text.
- `docs/guides/coding_guidelines.md` — kernel coding rules.
- `docs/guides/perf_guidelines.md` — performance rules for graph/vector/DB work.
- `../docs/STATE.md` — current cross-repo truth.

## Boundaries

- Keep the kernel clean: no plugin source, private corpora, `.env`, or secrets.
- Do not import from `../hive`; the kernel talks to adapters through typed ports.
- Port and plugin naming authority lives in `../docs/architecture/ports.md`.
- Cross-repo ADR authority lives in `../docs/decisions/`; older detailed ADR text
  is still being migrated from `docs/swarm_architecture_spec.md`.
- Scratch belongs in `tmp/`.

## Toolchain

- Erlang/OTP and Elixir are managed by `mise` using `.tool-versions`.
- Python is `uv` only. Do not use `pip` or bare `python`.
- Python version is pinned by `.python-version`.
- Postgres + pgvector run through Docker using `infra/`.

## Common Commands

Run from this repo root:

```bash
task setup
task lint
task test
task check
task proto
```

Targeted checks:

```bash
cd ml && uv run pytest -q
cd cli && uv run pytest -q
cd kernel && mise exec -- mix test
```

If a tool is unavailable in the current shell, report that honestly.

## Coding Rules

- Functional core, side effects at boundaries.
- Fail loud; never return success-shaped error values.
- Structured LLM I/O only; do not parse decisions from free-text substrings.
- Time is timezone-aware UTC at ingestion boundaries.
- Unicode is NFC; do not apply lossy ASCII folding.
- Config comes from env/runtime config, not hardcoded constants.
- Generated Protobuf stubs stay generated; regenerate via `task proto`.

## Verification

Before calling work done, run the narrowest relevant checks and report them.
Prefer `task check` for repo-wide work. Use integration tests only when the
required live services are intentionally available.

## Instruction Files

This file is the canonical agent guide for the `swarm/` repo. `CLAUDE.md` is
only a pointer to this file.
