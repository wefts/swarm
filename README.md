# Heterogeneous Cognitive Swarm

A persistent, local-first assistant built as a **heterogeneous cognitive swarm**:
many cheap specialized processes run continuously over a shared knowledge graph;
expensive large models are the rare escalation (cost asymmetry). Coordination is
stigmergic — agents leave traces in the graph rather than talking directly
(a blackboard architecture with a consilium of large models on top).

This repo is the **kernel**: Elixir/OTP (logic, coordination) + Python (ML).
Connectors, workers, channels, skills, and data corpora are plugins that live
**outside** the repo and attach through typed ports. The repo stays clean and
public; secrets never land here.

> Status: architecture and key decisions are locked; the storage engine is
> chosen (Postgres + pgvector, decided by spike). The two-language skeleton is
> scaffolded — the kernel boots, connects to Postgres, and talks Protobuf/gRPC
> to the Python ML service. Domain code is the next phase. See the build order
> in the system architecture, §12.

## Documentation

| Document | What it covers | Lang |
| --- | --- | --- |
| [docs/swarm_architecture_spec.md](docs/swarm_architecture_spec.md) | How the swarm *thinks* — 17 domains, principles, Design Decisions (ADR-1..9) | EN |
| [docs/failure_modes_and_open_problems.md](docs/failure_modes_and_open_problems.md) | Failure catalog (anti-patterns) + open problems | EN |
| [docs/system_architecture.md](docs/system_architecture.md) | How the software is *built* — microkernel, ports, deployment, repo layout | EN |
| [docs/storage_engine_spike.md](docs/storage_engine_spike.md) | Storage-engine decision record (the spike + outcome) | EN |
| [docs/guides/](docs/guides/) | Coding & performance guidelines | EN |
| [CLAUDE.md](CLAUDE.md) | Operating instructions for Claude in this repo | EN |

## Architecture in one picture

- **Logic / coordination** — Elixir/OTP kernel (supervision, leases, leader,
  distribution).
- **Intelligence** — Python ML services (embeddings, inference) over gRPC.
- **Memory** — Postgres + pgvector (graph + vectors), behind a storage port.

Everything that grows over time — data sources, capabilities, channels — is an
adapter behind a port, not a change to the kernel.

## Repository layout

```text
proto/        Protobuf contracts (ports + the Elixir<->Python boundary + Core API)
kernel/       Elixir/OTP app `:swarm` (graph, gate, consilium, Core API server)
ml/           Python ML service (uv; embeddings + generation over gRPC)
cli/          Python CLI channel (uv; Typer + Rich over the Core API)
infra/        docker-compose for stateful infra (Postgres+pgvector)
docs/         Architecture, decisions (ADR-1..9), guides
```

Plugins/adapters and corpora live **outside** the repo, normally in a sibling
private instance repo called `hive/`, reached via `SWARM_PLUGINS_DIR` /
`SWARM_DATA_DIR` (system architecture §13).

Typical local checkout:

```text
swarm/
  swarm/  public kernel/control-plane repo
  hive/   private instance/deployment repo
```

## Toolchain

| Tool | Version | Managed by |
| --- | --- | --- |
| Erlang/OTP | 28.5 | mise (`.tool-versions`) |
| Elixir | 1.19.5 (otp-28) | mise (`.tool-versions`) |
| Python | 3.13 | uv (`.python-version`) |
| Postgres + pgvector | 16 + 0.8.x | Docker (`infra/`) |
| Protobuf / gRPC | Elixir + Python gRPC/protobuf libs | per-stack |

mise manages **Erlang + Elixir only**; **Python is uv-only** (`uv run`, never
`pip`/bare `python`). Install mise once (`curl https://mise.run | sh`), then
`mise install` from the repo root builds the pinned pair.

## Development

Gates run through [Task](https://taskfile.dev) (`Taskfile.yml`), both stacks:

```bash
task db:up      # start Postgres+pgvector (infra/docker-compose.yml)
task setup      # generate proto stubs, fetch deps, create + migrate the DB
task lint       # markdown + Python (ruff/ty) + Elixir (format/credo/dialyzer)
task test       # Python (pytest) + Elixir (mix test)
task check      # lint + test
task proto      # regenerate Protobuf stubs (Python + Elixir)
```

Prove the cross-language boundary end to end: run the ML service
(`cd ml && uv run swarm-ml`), then `cd kernel && mix test --include integration`
— the Elixir kernel calls the Python `Embed` RPC and gets a vector back.

- Quality gates, review, and the Spark delivery loop are Claude skills:
  `swarm-check`, `swarm-review`, `swarm-sync`.
- Stateful infra runs in Docker; the app (kernel, ML) runs on the host.
- See [docs/guides/](docs/guides/) for engineering standards.
