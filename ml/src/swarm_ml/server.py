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
_OLLAMA_GEN_TIMEOUT_S = 300  # generation on large local models is slow


class OllamaEmbedError(Exception):
    """Ollama was unreachable or returned an unusable embedding response."""


class OllamaGenerateError(Exception):
    """Ollama was unreachable or returned an unusable generation response."""


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


def _call_ollama_generate(
    base_url: str, model: str, prompt: str, system: str, json_mode: bool
) -> str:
    """POST to Ollama `/api/generate`; return the response text. Fail loud."""
    body: dict[str, object] = {"model": model, "prompt": prompt, "stream": False}
    if system:
        body["system"] = system
    if json_mode:
        body["format"] = "json"

    req = urllib.request.Request(
        f"{base_url}/api/generate",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=_OLLAMA_GEN_TIMEOUT_S) as response:
            parsed = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise OllamaGenerateError(f"Ollama HTTP {exc.code}: {exc.reason}") from exc
    except OSError as exc:
        raise OllamaGenerateError(f"Ollama unreachable at {base_url}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise OllamaGenerateError(f"Ollama returned invalid JSON: {exc}") from exc

    text = parsed.get("response")
    if not isinstance(text, str) or text == "":
        raise OllamaGenerateError(f"Ollama response missing 'response': {parsed!r}")
    return text


class GeneratorService(embed_pb2_grpc.GeneratorServicer):
    """Text generation on the local fleet (consilium panel + judge)."""

    def __init__(self, *, ollama_base_url: str) -> None:
        self._base = ollama_base_url

    def Generate(  # method name fixed by the generated gRPC servicer
        self,
        request: embed_pb2.GenerateRequest,
        context: grpc.ServicerContext,
    ) -> embed_pb2.GenerateResponse:
        try:
            text = _call_ollama_generate(
                self._base, request.model, request.prompt, request.system, request.json
            )
        except OllamaGenerateError as exc:
            _LOG.error("generate failed: %s", exc)
            context.abort(grpc.StatusCode.UNAVAILABLE, str(exc))
            raise  # unreachable: abort() raises

        return embed_pb2.GenerateResponse(text=text, model=request.model)


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
    embed_pb2_grpc.add_GeneratorServicer_to_server(
        GeneratorService(ollama_base_url=config.ollama_base_url), server
    )
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
