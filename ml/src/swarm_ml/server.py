"""gRPC ML service: the Embedder (Model port) over the Elixir<->Python boundary.

`Embed` calls Ollama (`/api/embed`) for real vectors. The contract is unchanged;
failures are fail-loud (a typed error → gRPC UNAVAILABLE), never a zero vector.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from concurrent import futures

import grpc
import numpy as np

from swarm_ml._gen import embed_pb2, embed_pb2_grpc
from swarm_ml.config import ServerConfig, load_config

_LOG = logging.getLogger("swarm_ml.server")
_OLLAMA_TIMEOUT_S = 60


class OllamaEmbedError(Exception):
    """Ollama was unreachable or returned an unusable embedding response."""


def _call_ollama(base_url: str, model: str, texts: list[str]) -> list[list[float]]:
    """POST the whole batch to Ollama `/api/embed`; return the raw vectors.

    One request per batch (not per text). Raises `OllamaEmbedError` on any
    transport or shape problem — the caller decides the gRPC status.
    """
    payload = json.dumps({"model": model, "input": texts}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/api/embed",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=_OLLAMA_TIMEOUT_S) as response:
            parsed = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise OllamaEmbedError(f"Ollama HTTP {exc.code}: {exc.reason}") from exc
    except OSError as exc:  # URLError, connection refused, timeout
        raise OllamaEmbedError(f"Ollama unreachable at {base_url}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise OllamaEmbedError(f"Ollama returned invalid JSON: {exc}") from exc

    embeddings = parsed.get("embeddings")
    if not isinstance(embeddings, list) or not embeddings:
        raise OllamaEmbedError(f"Ollama response missing 'embeddings': {parsed!r}")
    return embeddings


class EmbedderService(embed_pb2_grpc.EmbedderServicer):
    """Embeds text via Ollama; the response namespace is the model (ADR-6)."""

    def __init__(self, *, config: ServerConfig) -> None:
        self._config = config

    def Embed(  # method name fixed by the generated gRPC servicer
        self,
        request: embed_pb2.EmbedRequest,
        context: grpc.ServicerContext,
    ) -> embed_pb2.EmbedResponse:
        cfg = self._config
        texts = list(request.texts)

        if not texts:
            return embed_pb2.EmbedResponse(vectors=[], namespace=cfg.embed_model, dim=cfg.embed_dim)

        try:
            raw = _call_ollama(cfg.ollama_base_url, cfg.embed_model, texts)
        except OllamaEmbedError as exc:
            _LOG.error("embed failed: %s", exc)
            context.abort(grpc.StatusCode.UNAVAILABLE, str(exc))
            raise  # unreachable: abort() raises — keeps the type-checker honest

        block = np.asarray(raw, dtype=np.float32)
        if block.ndim != 2 or block.shape != (len(texts), cfg.embed_dim):
            msg = f"unexpected embedding shape {block.shape}, want ({len(texts)}, {cfg.embed_dim})"
            _LOG.error(msg)
            context.abort(grpc.StatusCode.INTERNAL, msg)
            raise OllamaEmbedError(msg)  # unreachable

        # Namespace = model: vectors from different models are never mixed (ADR-6).
        vectors = [embed_pb2.Vector(values=row) for row in block.tolist()]
        return embed_pb2.EmbedResponse(
            vectors=vectors, namespace=cfg.embed_model, dim=block.shape[1]
        )


def build_server(config: ServerConfig) -> tuple[grpc.Server, int]:
    """Build and bind the server. Returns the server and the bound port.

    Binding here (not in ``main``) lets tests bind ``:0`` and learn the port.
    """
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=config.max_workers))
    embed_pb2_grpc.add_EmbedderServicer_to_server(EmbedderService(config=config), server)
    port = server.add_insecure_port(config.bind)
    return server, port


def main() -> None:
    """Entry point (``swarm-ml``): serve until terminated."""
    logging.basicConfig(level=logging.INFO)
    config = load_config()
    server, port = build_server(config)
    server.start()
    _LOG.info("swarm-ml listening on port %s (model=%s)", port, config.embed_model)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
