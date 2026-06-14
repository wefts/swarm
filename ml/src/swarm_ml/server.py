"""gRPC ML service: the Embedder (Model port) over the Elixir<->Python boundary.

Stub stage: ``Embed`` returns a fixed-size zero vector per input text. This
proves the cross-language contract end to end; real model inference replaces the
body later without touching the contract or the kernel.
"""

from __future__ import annotations

import logging
from concurrent import futures

import grpc
import numpy as np

from swarm_ml._gen import embed_pb2, embed_pb2_grpc
from swarm_ml.config import ServerConfig, load_config

_LOG = logging.getLogger("swarm_ml.server")


class EmbedderService(embed_pb2_grpc.EmbedderServicer):
    """Returns one fixed-size zero vector per input text (stub)."""

    def __init__(self, *, embed_dim: int, namespace: str) -> None:
        self._dim = embed_dim
        self._namespace = namespace

    def Embed(  # method name fixed by the generated gRPC servicer
        self,
        request: embed_pb2.EmbedRequest,
        context: grpc.ServicerContext,
    ) -> embed_pb2.EmbedResponse:
        namespace = request.namespace or self._namespace
        n = len(request.texts)
        # Vectorized: build the whole (n, dim) block at once, never a per-text
        # Python loop doing vector math (perf_guidelines: think in arrays).
        block = np.zeros((n, self._dim), dtype=np.float32)
        vectors = [embed_pb2.Vector(values=row) for row in block.tolist()]
        return embed_pb2.EmbedResponse(
            vectors=vectors,
            namespace=namespace,
            dim=self._dim,
        )


def build_server(config: ServerConfig) -> tuple[grpc.Server, int]:
    """Build and bind the server. Returns the server and the bound port.

    Binding here (not in ``main``) lets tests bind ``:0`` and learn the port.
    """
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=config.max_workers))
    servicer = EmbedderService(embed_dim=config.embed_dim, namespace=config.namespace)
    embed_pb2_grpc.add_EmbedderServicer_to_server(servicer, server)
    port = server.add_insecure_port(config.bind)
    return server, port


def main() -> None:
    """Entry point (``swarm-ml``): serve until terminated."""
    logging.basicConfig(level=logging.INFO)
    config = load_config()
    server, port = build_server(config)
    server.start()
    _LOG.info("swarm-ml listening on port %s (embed_dim=%s)", port, config.embed_dim)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
