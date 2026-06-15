"""Service configuration, read from the environment at call time.

No module-level singletons and no import-time I/O: `load_config` is called
inside functions so a bare import (tests, ``--help``) never touches the
environment. Secrets, if any, come from env — never committed.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

# Defaults only — the live config is whatever the environment says at call time.
_DEFAULT_BIND = "127.0.0.1:50051"
_DEFAULT_EMBED_DIM = 1024  # bge-m3
_DEFAULT_MAX_WORKERS = 8
_DEFAULT_NAMESPACE = "bge-m3"
_DEFAULT_EMBED_MODEL = "bge-m3"
_DEFAULT_OLLAMA_BASE_URL = "http://localhost:11434"


@dataclass(frozen=True, slots=True)
class ServerConfig:
    """Immutable server config. ``frozen`` stops rebinding of the fields."""

    bind: str
    embed_dim: int
    max_workers: int
    namespace: str
    embed_model: str
    ollama_base_url: str


def load_config() -> ServerConfig:
    """Build the config from the environment. Fail loud on malformed ints."""
    return ServerConfig(
        bind=os.environ.get("SWARM_ML_BIND", _DEFAULT_BIND),
        embed_dim=_env_int("SWARM_ML_EMBED_DIM", _DEFAULT_EMBED_DIM),
        max_workers=_env_int("SWARM_ML_MAX_WORKERS", _DEFAULT_MAX_WORKERS),
        namespace=os.environ.get("SWARM_ML_NAMESPACE", _DEFAULT_NAMESPACE),
        embed_model=os.environ.get("SWARM_EMBED_MODEL", _DEFAULT_EMBED_MODEL),
        ollama_base_url=os.environ.get("OLLAMA_BASE_URL", _DEFAULT_OLLAMA_BASE_URL),
    )


def _env_int(key: str, default: int) -> int:
    raw = os.environ.get(key)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        # Fail loud: a misconfigured int is a config error, not a silent default.
        raise ValueError(f"{key} must be an integer, got {raw!r}") from exc
