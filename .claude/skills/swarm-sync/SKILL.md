---
name: swarm-sync
description: >
  Deliver code to the Spark machine and run it there (no CI). Use when the user
  says "sync", "push to spark", "run on spark", "test on spark", "deploy the
  spike". Work is edited locally, synced over ssh, executed on Spark.
---

# swarm-sync

No CI. The loop is: edit locally -> rsync over ssh -> run on Spark. Corporate
GitLab is the only CI option and is not set up; rsync is the working path.

## Connection facts

- Host: `spark.mpl.intranet`. **ssh without `user@`** — ssh config resolves the
  user (`sebor`); forcing `$USER` (searge) fails publickey.
- Spark is **aarch64** (Grace), Docker present, **uv** at `~/.local/bin/uv`
  (Python = uv only; `uv run` auto-installs deps).
- Repo on Spark: `~/Swarm/swarm`. The **whole repo** syncs both ways, **with
  git**; the spike lives under `tmp/spike` (no separate dir). Only
  dependency/build/cache folders are excluded.

## The loop

```bash
tmp/scripts/sync.sh push             # local -> Spark, mirror (--delete)
tmp/scripts/sync.sh pull             # Spark -> local, additive (brings results)
tmp/scripts/run_on_spark.sh <args>   # ssh: docker compose up + uv run spike
                                     # (runs in ~/Swarm/swarm/tmp/spike)
```

Targets and the exclude list live in `tmp/scripts/env.sh`. `push` mirrors —
don't edit git on both sides between syncs. `.venv`/`_build`/`deps`/caches are
never transferred (regenerated on each side).

When running ad hoc over ssh, always export the uv PATH first:

```bash
ssh spark.mpl.intranet 'export PATH="$HOME/.local/bin:$PATH"; cd <dir> && uv run ...'
```

## Environment split (keep local and Spark separate)

- Repo stays clean; plugins and test data live **outside** the repo, pointed to
  by env config (see system architecture §13).
- Local: your own test data/plugins. Spark: the real corpora (wiki/Confluence)
  in a sibling project folder, never committed.
- Stateful infra (Postgres, later Memgraph) runs in `docker compose`; app
  components (Elixir kernel, Python ML) run on the host via mix/uv.

## Ollama from containers

App runs on the host -> Ollama is plain `http://localhost:11434`. If a component
is containerized, add `extra_hosts: ["host.docker.internal:host-gateway"]` to its
compose service and set `OLLAMA_BASE_URL=http://host.docker.internal:11434`.
Never hardcode the URL — read it from env.
