"""Embedder tests: Ollama is mocked for unit tests; one marked integration test
hits real Ollama on Spark (run with `pytest -m integration`)."""

from __future__ import annotations

import json
from collections.abc import Iterator

import grpc
import pytest

from swarm_ml import server as server_mod
from swarm_ml._gen import embed_pb2, embed_pb2_grpc
from swarm_ml.config import ServerConfig, load_config
from swarm_ml.server import OllamaEmbedError, build_server

_DIM = 1024


def _config() -> ServerConfig:
    return ServerConfig(
        bind="127.0.0.1:0",
        embed_dim=_DIM,
        max_workers=2,
        namespace="bge-m3",
        embed_model="bge-m3",
        ollama_base_url="http://localhost:11434",
        ollama_keep_alive="-1",
        ollama_num_predict=512,
        ollama_num_ctx=32768,
    )


@pytest.fixture
def channel() -> Iterator[grpc.Channel]:
    server, port = build_server(_config())
    server.start()
    try:
        with grpc.insecure_channel(f"127.0.0.1:{port}") as chan:
            yield chan
    finally:
        server.stop(grace=None)


def test_embed_maps_ollama_vectors_and_stamps_model_namespace(channel, monkeypatch) -> None:
    fake = [[0.1] * _DIM, [0.2] * _DIM]
    monkeypatch.setattr(server_mod, "_call_ollama", lambda *_a, **_k: fake)

    stub = embed_pb2_grpc.EmbedderStub(channel)
    resp = stub.Embed(embed_pb2.EmbedRequest(texts=["alpha", "бета"], namespace="ignored"))

    assert resp.namespace == "bge-m3"  # ADR-6: response namespace is the model
    assert resp.dim == _DIM
    assert len(resp.vectors) == 2
    assert pytest.approx(resp.vectors[0].values[0]) == 0.1


def test_embed_empty_batch_skips_ollama(channel, monkeypatch) -> None:
    def boom(*_a, **_k):
        raise AssertionError("Ollama must not be called for an empty batch")

    monkeypatch.setattr(server_mod, "_call_ollama", boom)
    stub = embed_pb2_grpc.EmbedderStub(channel)
    resp = stub.Embed(embed_pb2.EmbedRequest(texts=[], namespace="x"))

    assert len(resp.vectors) == 0
    assert resp.dim == _DIM
    assert resp.namespace == "bge-m3"


def test_ollama_failure_aborts_unavailable_not_zero_vector(channel, monkeypatch) -> None:
    def boom(*_a, **_k):
        raise OllamaEmbedError("connection refused")

    monkeypatch.setattr(server_mod, "_call_ollama", boom)
    stub = embed_pb2_grpc.EmbedderStub(channel)

    with pytest.raises(grpc.RpcError) as excinfo:
        stub.Embed(embed_pb2.EmbedRequest(texts=["alpha"], namespace="x"))
    err = excinfo.value
    assert isinstance(err, grpc.Call)  # grpc.Call declares code(); RpcError does not
    assert err.code() == grpc.StatusCode.UNAVAILABLE


def test_wrong_dimension_aborts_internal(channel, monkeypatch) -> None:
    monkeypatch.setattr(server_mod, "_call_ollama", lambda *_a, **_k: [[0.0] * 8])
    stub = embed_pb2_grpc.EmbedderStub(channel)

    with pytest.raises(grpc.RpcError) as excinfo:
        stub.Embed(embed_pb2.EmbedRequest(texts=["alpha"], namespace="x"))
    err = excinfo.value
    assert isinstance(err, grpc.Call)
    assert err.code() == grpc.StatusCode.INTERNAL


def test_generate_returns_text_from_the_model(channel, monkeypatch) -> None:
    monkeypatch.setattr(
        server_mod, "_call_ollama_generate", lambda *_a, **_k: "hello from the fleet"
    )
    stub = embed_pb2_grpc.GeneratorStub(channel)
    resp = stub.Generate(embed_pb2.GenerateRequest(model="qwen3:8b", prompt="hi"))

    assert resp.text == "hello from the fleet"
    assert resp.model == "qwen3:8b"


def test_generate_failure_aborts_unavailable(channel, monkeypatch) -> None:
    def boom(*_a, **_k):
        raise server_mod.OllamaGenerateError("down")

    monkeypatch.setattr(server_mod, "_call_ollama_generate", boom)
    stub = embed_pb2_grpc.GeneratorStub(channel)

    with pytest.raises(grpc.RpcError) as excinfo:
        stub.Generate(embed_pb2.GenerateRequest(model="qwen3:8b", prompt="hi"))
    err = excinfo.value
    assert isinstance(err, grpc.Call)
    assert err.code() == grpc.StatusCode.UNAVAILABLE


class _FakeResp:
    def __init__(self, payload: dict) -> None:
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_a) -> bool:
        return False

    def read(self) -> bytes:
        return json.dumps(self._payload).encode("utf-8")


def test_generate_body_pins_residency_disables_thinking_and_caps_output(monkeypatch) -> None:
    # ADR-17 #1: the generate body must carry keep_alive (residency), think=false
    # (intermediate processors are not chat surfaces), and options.num_predict
    # (output cap) so an interactive ask never cold-loads and never runs away.
    captured: dict = {}

    def fake_urlopen(req, timeout=None):
        captured["body"] = json.loads(req.data.decode("utf-8"))
        return _FakeResp({"response": "ok"})

    monkeypatch.setattr(server_mod.urllib.request, "urlopen", fake_urlopen)
    out = server_mod._call_ollama_generate(
        "http://x", "m", "p", "", False, keep_alive="-1", num_predict=256, num_ctx=32768
    )
    assert out == "ok"
    # "-1" must reach Ollama as the NUMBER -1, not the string "-1" (a string "-1" is not a
    # valid Go duration → HTTP 400). A real duration string passes through unchanged.
    assert captured["body"]["keep_alive"] == -1
    assert captured["body"]["think"] is False
    # num_ctx sizes the KV cache to the real need (resident-memory saving)
    assert captured["body"]["options"] == {"num_predict": 256, "num_ctx": 32768}


def test_generate_no_options_when_num_predict_zero(monkeypatch) -> None:
    captured: dict = {}

    def fake_urlopen(req, timeout=None):
        captured["body"] = json.loads(req.data.decode("utf-8"))
        return _FakeResp({"response": "ok"})

    monkeypatch.setattr(server_mod.urllib.request, "urlopen", fake_urlopen)
    server_mod._call_ollama_generate(
        "http://x", "m", "p", "", False, keep_alive="5m", num_predict=0
    )
    assert captured["body"]["keep_alive"] == "5m"  # a real duration passes through as a string
    assert captured["body"]["think"] is False
    assert "options" not in captured["body"]


def test_embed_body_pins_residency(monkeypatch) -> None:
    captured: dict = {}

    def fake_urlopen(req, timeout=None):
        captured["body"] = json.loads(req.data.decode("utf-8"))
        return _FakeResp({"embeddings": [[0.0] * _DIM]})

    monkeypatch.setattr(server_mod.urllib.request, "urlopen", fake_urlopen)
    server_mod._call_ollama("http://x", "bge-m3", ["hi"], keep_alive="-1")
    assert captured["body"]["keep_alive"] == -1


def test_config_defaults_pin_residency_and_cap(monkeypatch) -> None:
    monkeypatch.delenv("OLLAMA_KEEP_ALIVE", raising=False)
    monkeypatch.delenv("OLLAMA_NUM_PREDICT", raising=False)
    monkeypatch.delenv("OLLAMA_NUM_CTX", raising=False)
    cfg = load_config()
    assert cfg.ollama_keep_alive == "-1"
    # generous cap: thinking models (qwen3:14b) reason for many tokens before answering; a
    # tight cap truncates them mid-thought and breaks extraction (learned live 2026-07-05).
    assert cfg.ollama_num_predict == 4096
    assert cfg.ollama_num_ctx == 32768


@pytest.mark.integration
def test_embed_real_ollama_returns_bge_m3_vectors(channel) -> None:
    stub = embed_pb2_grpc.EmbedderStub(channel)
    resp = stub.Embed(embed_pb2.EmbedRequest(texts=["привіт", "bonjour", "hello"], namespace="x"))

    assert resp.namespace == "bge-m3"
    assert resp.dim == _DIM
    assert len(resp.vectors) == 3
    # real vectors, not the old zero stub
    assert any(abs(v) > 0.0 for v in resp.vectors[0].values)
