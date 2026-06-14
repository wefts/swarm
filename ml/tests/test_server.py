"""End-to-end test of the Embedder over a real in-process gRPC channel."""

from __future__ import annotations

from collections.abc import Iterator

import grpc
import pytest

from swarm_ml._gen import embed_pb2, embed_pb2_grpc
from swarm_ml.config import ServerConfig
from swarm_ml.server import build_server

_DIM = 16


@pytest.fixture
def channel() -> Iterator[grpc.Channel]:
    config = ServerConfig(bind="127.0.0.1:0", embed_dim=_DIM, max_workers=2, namespace="test-v0")
    server, port = build_server(config)
    server.start()
    try:
        with grpc.insecure_channel(f"127.0.0.1:{port}") as chan:
            yield chan
    finally:
        server.stop(grace=None)


def test_embed_returns_one_fixed_size_zero_vector_per_text(channel: grpc.Channel) -> None:
    stub = embed_pb2_grpc.EmbedderStub(channel)
    resp = stub.Embed(embed_pb2.EmbedRequest(texts=["alpha", "бета", "丙"], namespace="test-v0"))

    assert resp.dim == _DIM
    assert resp.namespace == "test-v0"
    assert len(resp.vectors) == 3
    for vec in resp.vectors:
        assert len(vec.values) == _DIM
        assert all(v == 0.0 for v in vec.values)


def test_embed_empty_batch_returns_no_vectors(channel: grpc.Channel) -> None:
    stub = embed_pb2_grpc.EmbedderStub(channel)
    resp = stub.Embed(embed_pb2.EmbedRequest(texts=[], namespace="test-v0"))
    assert len(resp.vectors) == 0
    assert resp.dim == _DIM
