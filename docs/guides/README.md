# Engineering Guides

Reference standards for the swarm kernel (Elixir + Python, this repo).

- [`coding_guidelines.md`](coding_guidelines.md) — principles + per-language
  (Elixir/OTP, Python) rules, architecture boundaries, what to avoid.
- [`perf_guidelines.md`](perf_guidelines.md) — complexity is a design decision;
  traversal/vector/DB patterns; design for 10×; measure, don't argue. Include
  verbatim when delegating code to a model.

## Review and gates live as skills, not duplicated docs

- **`swarm-review`** skill — the review checklist (architecture boundaries, ADR
  invariants, hygiene). Single source of truth for review; not repeated here.
- **`swarm-check`** skill — the quality gates (markdownlint now; uv ruff/ty/pytest
  and mix format/credo/test as code lands).
- **`swarm-sync`** skill — the local → Spark delivery loop.

## Deferred

- **Style guide (CLI output).** The principles (no emoji, semantic color,
  left-aligned, Rich patterns) port from the prior project, but the concrete
  palette/tables are written when the CLI channel front exists, not before.
