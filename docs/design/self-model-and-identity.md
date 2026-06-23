---
status: built
implements: "swarm ADR-7 (Accepted) — ../decisions/0007-self-model-and-identity.md"
owner: swarm
---

# Spec: Self-model + asker identity (T8)

How the kernel answers "what do you know / how fresh / what can you do" from real
state, and how "my X" resolves to the asker. Implements swarm ADR-7.

## Self-model — `Core.status` / `KbStatus`

Returns, all from live state:

| Field | Source |
| --- | --- |
| `nodes`, `edges` | `count(*)` |
| `inventory` (`[{type, count}]`) | `GROUP BY type` |
| `last_activity` | `max(updated_at)` (ISO-8601, `""` if empty) |
| `namespaces` | embedding stamps (ADR-6) |
| `capabilities` | attached connectors (registry) + `consilium:N-model-panel` |

Wire: `StatusResponse` gains `inventory` (`TypeCount`), `last_activity`,
`capabilities`. `capabilities` is resilient — if the plugin registry is not
running it reports `[]` + the panel, never crashes.

## Asker identity — `AskRequest.viewer`

- `viewer` is the asker's **resolved canonical id**, supplied by the channel
  (which maps a platform user → the id; a deployment fact, not kernel).
- `Core.ask` detects a **first-person** query (`\b(my|mine|me)\b`):
  - **with** a viewer → retrieval is narrowed to the viewer's items
    (`key ILIKE %viewer%`), still scope-filtered (default-deny);
  - **without** a viewer → `identity_required` (a clear structured result, status
    `:not_found`), never a broad anonymous dump.
- A non-first-person query ignores `viewer` (no owner narrowing).

## Security note (read this)

The owner-match (`key ILIKE %viewer%`) is a **retrieval convenience**, not the
access boundary. The boundary is **scopes** (`Gate.Visibility`, ADR-5): a `viewer`
does not grant scope; the channel sets `scopes`. "my X" = the viewer's items
*within the scopes the channel already allowed*. Visibility-under-load is ADR-5's
named open problem; this ADR does not change it.

## The gate

- Kernel `test/swarm/core_identity_test.exs`: self-model reflects a real fixture
  (per-type counts, freshness, capability); "my X" + viewer → only that viewer's
  items; "my X" + no viewer → limited (identity_required); non-first-person
  ignores the viewer.
- CLI `tests/test_cli.py`: `--viewer` is passed through; `kb status` renders the
  self-model (inventory, freshness, capabilities) from structured fields.

## Limitations (honest scope)

- **Owner-match is a delimited-token match on `key`.** It resolves "my X" when the
  viewer id appears as a token in the node key (how connectors will key owned
  items); a richer owner/about edge is future work. It is not, and must not be
  used as, an access control — scopes are.
- **Freshness is last write activity**, graph-wide; per-source watermark freshness
  arrives with persisted connector watermarks (T3 follow-up).

## Acceptance

- `mix test` 115/0; credo `--strict` clean; dialyzer 0; format clean. CLI 7/0.
- `KbStatus` reflects a known fixture; `AskRequest.viewer` resolves "my X".
