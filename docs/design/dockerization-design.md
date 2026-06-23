---
date: 2026-06-22
status: Approved
scope: Change 1 done; Changes 2–4 documented follow-ons
owner: swarm
---

# Dockerization Design — Swarm packaging, Hive orchestration

## Problem

"Dockerize the application." Today only Postgres+pgvector is containerized
(`swarm/infra/docker-compose.yml`); the kernel (Elixir) and ML service (Python)
run on the host. We need a clear, canon-aligned plan for (a) building images for
the app itself and (b) orchestrating a full instance — without breaking the
local-first, host-based development loop.

A naming problem surfaced while scoping: the folder `swarm/infra/` reads as
"infrastructure / deployment," but per the canon **infra/deployment is Hive's
job**, not Swarm's. The folder is actually just the kernel's dev/test database
dependency.

## Decision: the boundary

- **`swarm/` = packaging + dev substrate.** It ships build recipes (Dockerfiles)
  and the one stateful dependency it needs to develop and test itself
  (Postgres). It is *not* a deployment orchestrator.
- **`hive/` = the sole orchestrator.** It is the only place that wires a full
  running instance, via the existing `include:` seam over the Swarm fragment
  plus private plugin adapters.
- **Routing rule (from `docs/standards/workflow.md`):** build/runtime recipe →
  `swarm/`; instance orchestration / deployment → `hive/`.

### Guiding principle: dev/prod harmony (invariant)

Two tracks, equally important, never traded off against each other:

- **Dev** — fast inner loop. App on the host (`mix` / `uv`), instant recompile,
  observer/debugger, only Postgres in Docker (`swarm/dev/`). Docker images NEVER
  enter this loop. `task test` / `task check` stay host-based and quick.
- **Prod** — reliable, reproducible, **offline-capable** packaged deployment:
  pinned images mirrored to a local registry, orchestrated from `hive/`.

Every change must leave dev as easy as before and prod as reliable as intended.
If a prod mechanism would slow the dev loop, it goes behind an opt-in, not the
default path.

### Why Postgres stays in Swarm (not moved to Hive)

`mix test` / `task test` / `task check` in `swarm/` require a live Postgres. That
is a **test gate of the kernel**, not a deployment concern. Keeping a single
Postgres compose fragment in Swarm lets Swarm self-test, while Hive remains the
sole full-instance orchestrator by `include:`-ing that fragment. Defining
Postgres once and including it (rather than duplicating or pointing Swarm's
Taskfile at `../hive`) is what prevents drift. All three repos are currently
public, so there is no public→private layering inversion.

## Scope: three sequential changes

### Change 1 — Rename `swarm/infra/` → `swarm/dev/` (implement now)

Pure refactor. No new runtime behavior. Signals "local dev/test substrate," not
"deployment." Mergeable on its own.

- Move `swarm/infra/docker-compose.yml` → `swarm/dev/docker-compose.yml`
  (filename unchanged — Hive's `include:` expects `docker-compose.yml`).
- Rewrite the compose header comment: this is a **dev/test substrate, not
  deployment**; deployment lives in Hive.
- Update all references (verified blast radius, 12 sites across 6 files):
  - `swarm/Taskfile.yml` — `db:up` / `db:down` keep their names; only the path
    becomes `-f dev/docker-compose.yml`. The descriptions mentioning
    `infra/docker-compose.yml` are updated too.
  - `swarm/README.md` — repo-layout block (line ~48), toolchain table (~71),
    `task db:up` comment (~83).
  - `swarm/AGENTS.md` — two mentions of `infra/`.
  - `swarm/kernel/config/runtime.exs` — comment referencing
    `infra/docker-compose.yml`.
  - `hive/docker-compose.yml` — the `include: ../swarm/infra/docker-compose.yml`
    path and the comment above it. (Cross-repo, justified: the boundary/name is
    what changes.)
  - `hive/AGENTS.md` — the `../swarm/infra/docker-compose.yml` reference.
- Verification: `docker compose -f swarm/dev/docker-compose.yml config`;
  `cd hive && docker compose config`; grep both repos for stray `infra/`.

### Change 2 — Packaging Dockerfiles in Swarm (follow-on)

Each service owns its Dockerfile + `.dockerignore`, co-located (per user
preference):

- `swarm/kernel/Dockerfile` + `swarm/kernel/.dockerignore` — multi-stage
  `mix release`. **Prerequisite (DONE):** `releases:` config added to `mix.exs`;
  `MIX_ENV=prod mix release` verified on the host — produces
  `_build/prod/rel/swarm/bin/swarm` and a 27.5 MB self-contained tarball (ERTS
  included, so an offline target needs no Erlang/Elixir install). `runtime.exs`
  is fully env-driven, so one release runs everywhere. Migrations in
  `priv/repo/migrations` ship inside the release and run AT DEPLOY (release
  `eval`), never at image build.
- `swarm/ml/Dockerfile` + `swarm/ml/.dockerignore` — multi-stage uv build,
  entrypoint `swarm-ml` (`swarm_ml.server:main`), Python 3.13.
- **The dev loop is untouched.** Development stays on the host (`mix` / `uv`),
  instant. Images are for packaging only and never enter `task test` / `task
  check`. The big build never sits in the inner loop.

### Change 3 — Full orchestration in Hive (follow-on, after Change 2)

`hive/docker-compose.yml` grows from "Postgres + commented plugins" to a full
instance:

- `include` the Swarm Postgres fragment (`../swarm/dev/docker-compose.yml`).
- `build:` / `image:` for the kernel and ML services (referencing Swarm's
  Dockerfiles).
- Plugin adapters (already skeletoned, commented).
- Wiring: kernel→postgres (`depends_on: service_healthy`), kernel→ml (gRPC),
  kernel/ml→Ollama on the host (`extra_hosts: host.docker.internal:host-gateway`,
  `OLLAMA_BASE_URL` never hardcoded), env via `.env` / `secrets.env`.

### Change 4 — Production & offline operation (in scope; user req 2026-06-22)

The product must survive being carried to a machine with **no internet** and
still boot the full stack. Promoted from "deferred" to a first-class deliverable.

- **Local registry.** Run `registry:2` locally; mirror every image the stack
  needs (kernel, ml, postgres/pgvector, plus build bases). Pin exact tags/digests
  — never `:latest`.
- **Offline proof.** With networking to public registries blocked, `docker
  compose up` on the full instance must succeed end to end. This is a test, run
  for real.
- **Belt-and-suspenders.** The release tarball (ERTS-included) is a second
  offline artifact, shippable by `scp`/USB, runnable with no Docker at all.
- Lives in `hive/` (orchestration) + `scripts/` (mirror helper).

## Testing & verification protocol (run after EVERY step)

No step is "done" until these produce real signal (per
`docs/standards/verification.md` — external signal over opinion):

1. **Build** — image builds clean; record build time + image size.
2. **Smoke** — the artifact boots and answers (release `rpc`, gRPC port, embed RPC).
3. **Benchmark** — record timings (build, boot-to-healthy, RPC latency) in the
   blackboard's benchmark table; reason about what to improve next.
4. **Liveness / no-zombie** — `docker ps` healthy; no orphaned containers,
   dangling images, or stray host processes; clean up before moving on.
5. **Soak (milestone gate)** — once the full stack is up, a multi-hour run
   watching RAM / file descriptors / restart counts; report drift, not just "it
   ran". The machine stays on, so this is feasible.

## Execution model (multi-agent + blackboard)

- A **blackboard** file (`scratchpad/BLACKBOARD.md`) is the shared trace: step
  plan, environment facts, benchmark table, findings, decisions. Stigmergic, in
  the spirit of the Swarm architecture itself.
- **Heterogeneous agents.** Local ollama coder models (qwen3-coder, devstral)
  draft artifacts; Codex / `swarm-review` act as independent critic. The
  orchestrator keeps ALL real verification (build/run/soak/liveness) in the real
  environment — agents draft and critique, reality decides.

## Out of scope

- Kernel `mix release` configuration itself (kernel task; blocks Change 2).
- CI pipelines (no CI; `task` is the gate).
- Kubernetes / cluster deployment (`system_architecture.md` §9 future path; the
  gRPC port ABI is invariant, so this grows without kernel changes).

## Verification

Per `docs/standards/verification.md`: prefer external signal. For Change 1 that
is `docker compose config` (both files) + a clean grep for `infra/`, plus an
independent Codex review of the diff. Report honestly which checks ran.
