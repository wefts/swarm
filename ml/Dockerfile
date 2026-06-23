# syntax=docker/dockerfile:1
#
# PRODUCTION image for the Swarm ML service (Python/uv, gRPC Embedder).
# Dev runs on the host via uv — this image is the packaged prod artifact only.
#
# Base: Docker Hardened Images (DHI), debian12/glibc — manylinux wheels
# (numpy, grpcio) install cleanly. Runtime is distroless + non-root (uid 65532),
# no shell. Build context is the swarm/ ROOT (not ml/) so proto/ is reachable:
#   docker build -f ml/Dockerfile -t swarm-ml:0.1.0 .
# Proto stubs are GENERATED here from canonical proto/*.proto (they are
# gitignored, never copied from the host) — reproducible by construction.
# Registry tier: local `localhost:5000` (offline) → Smile public (default, commit-safe)
# → upstream. Digests are content-addressed (mirror-independent). uv stays on ghcr (public).
ARG DHI_REGISTRY=dhi.smile.fr
# debian13 over debian12: 0 CRITICAL CVEs (vs 2) at the same size. (trivy-measured)
ARG DHI_PY_DEV=${DHI_REGISTRY}/python:3.13-debian13-dev@sha256:8dae89c2868f96d7de0cc06fd9c6e87bb242197f4ce07d5a5c73e0de5f009eb8
ARG DHI_PY_RUN=${DHI_REGISTRY}/python:3.13-debian13@sha256:6e8db8c9c5e95077a0f387c6196dfd92bdd5872370987b73e3d4d843b04f0628
# uv lives on ghcr (public); parameterized so offline builds can point it local.
ARG UV_REGISTRY=ghcr.io
ARG UV_IMAGE=${UV_REGISTRY}/astral-sh/uv:0.11.23@sha256:d0a0a753ab981624b49c97abc98821c1c09f4ca69d1ef5cee69c501be3d88479

# uv binary as a named stage — `COPY --from` can't take a variable directly, so
# resolve the (parameterized) image here and copy from the stage below.
FROM ${UV_IMAGE} AS uvbin

# ---- build stage --------------------------------------------------------
FROM ${DHI_PY_DEV} AS build
USER root
COPY --from=uvbin /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0 \
    UV_PYTHON=/opt/python/bin/python3
WORKDIR /app

# Deps as a cached layer (dev group included: grpcio-tools generates the stubs).
COPY ml/pyproject.toml ml/uv.lock ./
RUN uv sync --frozen --no-install-project

# Proto contracts + service source.
COPY proto /proto
COPY ml/ ./

# Generate gRPC stubs (identical to Taskfile `proto:py`), then install the
# project and prune dev deps so the runtime venv is lean.
RUN mkdir -p src/swarm_ml/_gen \
 && uv run python -m grpc_tools.protoc -I /proto \
      --python_out=src/swarm_ml/_gen \
      --grpc_python_out=src/swarm_ml/_gen \
      --pyi_out=src/swarm_ml/_gen \
      /proto/embed.proto \
 && touch src/swarm_ml/_gen/__init__.py \
 && sed -i -E 's/^import embed_pb2 as/from . import embed_pb2 as/' src/swarm_ml/_gen/embed_pb2_grpc.py \
 && uv sync --frozen --no-dev

# ---- runtime stage (DHI distroless, non-root, no shell) -----------------
FROM ${DHI_PY_RUN} AS runtime
LABEL org.opencontainers.image.title="swarm-ml" \
      org.opencontainers.image.description="Swarm ML service: embeddings/inference over gRPC" \
      org.opencontainers.image.source="https://github.com/wefts/swarm" \
      org.opencontainers.image.version="0.1.0"
ENV PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH" \
    SWARM_ML_BIND=0.0.0.0:50051 \
    OLLAMA_BASE_URL=http://host.docker.internal:11434
WORKDIR /app
COPY --from=build --chown=65532:65532 /app /app

EXPOSE 50051
# Liveness: TCP-connect to the gRPC bind port (bound = serving). No shell in the
# image, so this is exec-form via the interpreter.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["python3", "-c", "import socket; socket.create_connection(('127.0.0.1', 50051), 3).close()"]
ENTRYPOINT ["/app/.venv/bin/swarm-ml"]
