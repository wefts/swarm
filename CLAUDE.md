# CLAUDE.md

Operating instructions for Claude working in this repo (the swarm kernel).

## What this is

This repo is the **kernel** of a heterogeneous cognitive swarm: Elixir/OTP
(logic, coordination) + Python (ML), both in-repo and public. Plugins/adapters
and corpora live outside the repo and attach via typed ports. Read
[README.md](README.md) and [docs/](docs/) for the full picture; the locked
decisions are ADR-1..9 in
[docs/swarm_architecture_spec.md](docs/swarm_architecture_spec.md).

## Skills (use them)

- **swarm-check** — run quality gates before declaring work done.
- **swarm-review** — review diffs against architecture rules + ADR invariants.
- **swarm-sync** — deliver and run on the Spark machine (no CI).

## Machine context

- **Spark** (`spark.mpl.intranet`) is the runtime: aarch64 (Grace), Docker,
  Ollama on the host (`localhost:11434`) with a local model fleet.
- ssh **without** `user@` (ssh config resolves the user); repo on Spark lives at
  `~/Swarm/swarm`.
- **Python is uv-only** (`uv run`, never `pip`/bare `python`). uv at
  `~/.local/bin/uv`.
- Delivery is rsync over ssh, then run remotely — there is no CI.

## Standing constraints

- **Clean repo.** No plugin/adapter code, no corpora (wiki/Confluence/tickets),
  no secrets. Scratch goes in `tmp/` (gitignored).
- **Plugins and data live outside the repo**, reached via `SWARM_PLUGINS_DIR` /
  `SWARM_DATA_DIR` (system architecture §13). Local and Spark differ only by
  these env values.
- **Microkernel.** Never add a concrete connector/worker/channel/model/skill to
  the kernel — implement the port; the adapter lives outside.
- **Fail loud.** No success-shaped error values; no silent `except`.
- **Structured LLM I/O.** No decisions parsed from free-text substrings; fence
  untrusted text; code owns IDs/lists.
- **tz-aware UTC** at the ingestion boundary; **NFC** Unicode, no lossy folding.
- **Config, not constants**; read config at function scope; secrets from env.
- **snake_case** for files, scripts, and functions.
- Run the gates (`swarm-check`) before saying anything is done; surface real
  output, do not paper over failures.

## Standards

Follow [docs/guides/coding_guidelines.md](docs/guides/coding_guidelines.md) and
[docs/guides/perf_guidelines.md](docs/guides/perf_guidelines.md). When delegating
code to a model, include the performance guidelines verbatim — complexity shape
is a design decision, not a later optimization.

## Markdownlint

Docs are linted via the root `.markdownlint.yaml`. Run `markdownlint` from the
**repo root** (config is not found from `docs/`).
