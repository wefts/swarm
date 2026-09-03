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


def _keep_alive(raw: str) -> object:
    """Coerce a keep_alive config value to what Ollama accepts.

    Ollama takes keep_alive as a NUMBER (seconds; -1 = forever, 0 = unload now) OR a Go
    DURATION string ("10m", "24h"). A bare integer-looking STRING ("-1", "300") is NOT a
    valid duration and returns HTTP 400 — so send integer-looking values as an int and pass
    real durations through as a string.
    """
    try:
        return int(raw)
    except ValueError:
        return raw


def _call_ollama(
    base_url: str, model: str, texts: list[str], keep_alive: str = "-1"
) -> list[list[float]]:
    """POST the whole batch to Ollama `/api/embed`; return the raw vectors.

    One request per batch (not per text). Raises `OllamaEmbedError` on any
    transport or shape problem — the caller decides the gRPC status. `keep_alive`
    pins the embedder resident (no cold-load tax on the retrieval/disagreement path).
    """
    payload = json.dumps(
        {"model": model, "input": texts, "keep_alive": _keep_alive(keep_alive)}
    ).encode("utf-8")
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
    base_url: str,
    model: str,
    prompt: str,
    system: str,
    json_mode: bool,
    keep_alive: str = "-1",
    num_predict: int = 0,
    num_ctx: int = 0,
) -> str:
    """POST to Ollama `/api/generate`; return the response text. Fail loud.

    `keep_alive` pins the fleet model resident (kills the interactive cold-load tax);
    `num_predict` (>0) hard-caps output tokens (panel/judge are intermediate processors,
    not chatbots — an uncapped generation is pure latency); `num_ctx` (>0) sizes the KV
    cache to the real need (a model's huge default context wastes resident memory). ADR-17 #1.
    """
    body: dict[str, object] = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "keep_alive": _keep_alive(keep_alive),
        # This service is for intermediate processors: consilium panel/judge,
        # extraction and confirmation. Their output is consumed by code, not by
        # a human chat surface, so model "thinking" is pure latency and can hide
        # the final JSON behind an empty `{}` response under `format: json`.
        "think": False,
    }
    if system:
        body["system"] = system
    if json_mode:
        body["format"] = "json"

    options = {}
    if num_predict > 0:
        options["num_predict"] = num_predict
    if num_ctx > 0:
        options["num_ctx"] = num_ctx
    if options:
        body["options"] = options

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

    def __init__(self, *, config: ServerConfig) -> None:
        self._config = config

    def Generate(  # method name fixed by the generated gRPC servicer
        self,
        request: embed_pb2.GenerateRequest,
        context: grpc.ServicerContext,
    ) -> embed_pb2.GenerateResponse:
        cfg = self._config
        try:
            text = _call_ollama_generate(
                cfg.ollama_base_url,
                request.model,
                request.prompt,
                request.system,
                request.json,
                keep_alive=cfg.ollama_keep_alive,
                num_predict=cfg.ollama_num_predict,
                num_ctx=cfg.ollama_num_ctx,
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
            raw = _call_ollama(
                cfg.ollama_base_url, cfg.embed_model, texts, keep_alive=cfg.ollama_keep_alive
            )
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
    # Permit the kernel's client-side keepalive PINGs on long-lived, idle
    # channels. The kernel holds a small pool of persistent gRPC channels (it must
    # NOT reconnect per call — that path crashes grpc-elixir 0.11.5 on disconnect)
    # and PINGs them to detect a half-open connection promptly. gRPC's server
    # defaults are hostile to that: ``max_pings_without_data`` (2) plus a 5-minute
    # ``min_ping_interval_without_data_ms`` make the server GOAWAY an idle, pinging
    # client after ~40s, forcing needless reconnect churn. These options let idle
    # keepalive pings through so the channels actually stay long-lived.
    keepalive_options = [
        ("grpc.keepalive_permit_without_calls", 1),
        ("grpc.http2.max_pings_without_data", 0),
        ("grpc.http2.min_ping_interval_without_data_ms", 10_000),
    ]
    server = grpc.server(
        futures.ThreadPoolExecutor(max_workers=config.max_workers),
        options=keepalive_options,
    )
    embed_pb2_grpc.add_EmbedderServicer_to_server(EmbedderService(config=config), server)
    embed_pb2_grpc.add_GeneratorServicer_to_server(GeneratorService(config=config), server)
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
