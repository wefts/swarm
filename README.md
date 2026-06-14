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
> chosen (Postgres + pgvector, decided by spike). Kernel implementation is the
> next phase. See the build order in the system architecture, §12.

## Documentation

| Document | What it covers | Lang |
| --- | --- | --- |
| [docs/swarm_architecture_spec.md](docs/swarm_architecture_spec.md) | How the swarm *thinks* — 17 domains, principles, Design Decisions (ADR-1..9) | UA |
| [docs/failure_modes_and_open_problems.md](docs/failure_modes_and_open_problems.md) | Failure catalog (anti-patterns) + open problems | UA |
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

## Development

- Quality gates, review, and the Spark delivery loop are Claude skills:
  `swarm-check`, `swarm-review`, `swarm-sync`.
- Python is **uv-only**. Stateful infra runs in Docker; the app runs on the host.
- See [docs/guides/](docs/guides/) for engineering standards.
