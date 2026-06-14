---
name: swarm-check
description: >
  Run the swarm project's quality gates before declaring work done. Use when the
  user says "check", "run gates", "lint", "verify", "is it clean", or after
  editing docs/code in this repo. Detects what is present (docs, Python, Elixir)
  and runs the matching checks. Python is uv-only.
---

# swarm-check

Run the project gates and report pass/fail plainly. Never claim "clean" without
running them. Fail loud: surface the actual error output, do not summarize away.

## Preferred: the Taskfile (both stacks at once)

The gates are wired into the root `Taskfile.yml`. From the repo root, with
Postgres up (`task db:up`) and the toolchain on PATH (mise + uv):

```bash
task lint    # markdown + Python (ruff/ty) + Elixir (format/credo/dialyzer)
task test    # Python (pytest) + Elixir (mix test)
task check   # lint + test
```

`task` runs Elixir through `mise exec` (reads `.tool-versions`) and Python
through `uv`. The Elixir tests auto-create + migrate the DB, so Postgres must be
running first.

## Fallback: run the underlying tools directly

If `task` is unavailable, run the same gates by hand.

- **Markdown** (run from the **repo root** — `.markdownlint.yaml` lives there):

  ```bash
  npx --no-install markdownlint-cli2 "*.md" "docs/**/*.md" ".claude/**/*.md"
  ```

- **Python** (`ml/`, uv-only — never `pip`/`python`):

  ```bash
  uv run ruff check .
  uv run ruff format --check .
  uv run ty check        # or: uv run mypy .
  uv run pytest -q
  ```

- **Elixir** (`kernel/`, via `mise exec --`):

  ```bash
  mix format --check-formatted
  mix credo --strict
  mix dialyzer
  mix test
  ```

## Rules

- Run every applicable gate, not just the first. Report each result.
- A non-zero exit is a failure — say so with the output, do not paper over it.
- Tables/long lines in Markdown are fine (MD013/MD060 are disabled in
  `.markdownlint.yaml`); structural rules are not — fix those in the doc.
- If a gate tool is missing, say which and how to get it; do not skip silently.
