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

## Always

- **Markdown** (docs are part of the public repo): run from the **repo root**
  (the `.markdownlint.yaml` lives there; running from `docs/` misses it).

  ```bash
  markdownlint docs/*.md
  ```

## If a Python package is present (`pyproject.toml`)

Python is **uv-only** — never call `pip`/`python` directly.

```bash
uv run ruff check .
uv run ruff format --check .
uv run ty check        # or: uv run mypy .
uv run pytest -q
```

## If an Elixir project is present (`mix.exs`)

```bash
mix format --check-formatted
mix credo --strict
mix test
```

## Rules

- Run every applicable gate, not just the first. Report each result.
- A non-zero exit is a failure — say so with the output, do not paper over it.
- Tables/long lines in Markdown are fine (MD013/MD060 are disabled in
  `.markdownlint.yaml`); structural rules are not — fix those in the doc.
- If a gate tool is missing, say which and how to get it; do not skip silently.
