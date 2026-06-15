"""CLI unit tests against a faked Core API (no live kernel)."""

from __future__ import annotations

import grpc
import pytest
from typer.testing import CliRunner

from swarm_cli import main as cli
from swarm_cli._gen import core_pb2

runner = CliRunner()


def test_ask_renders_answer_citations_and_footer(monkeypatch) -> None:
    class FakeStub:
        def Ask(self, _req: core_pb2.AskRequest) -> core_pb2.AskResponse:
            return core_pb2.AskResponse(
                answer="Postgres + pgvector.",
                confidence=0.82,
                tier="tier_tools",
                citations=[
                    core_pb2.Citation(source="file", ref="/docs/storage.md", confidence=0.9)
                ],
            )

    monkeypatch.setattr(cli, "_stub", lambda: FakeStub())
    result = runner.invoke(cli.app, ["ask", "which storage engine?"])

    assert result.exit_code == 0
    assert "Postgres + pgvector." in result.stdout
    assert "/docs/storage.md" in result.stdout
    assert "tier_tools" in result.stdout


def test_kb_search_renders_hits(monkeypatch) -> None:
    class FakeStub:
        def KbSearch(self, _req: core_pb2.SearchRequest) -> core_pb2.SearchResponse:
            return core_pb2.SearchResponse(
                hits=[core_pb2.SearchHit(id=1, type="file", key="/docs/billing.md", score=1.0)]
            )

    monkeypatch.setattr(cli, "_stub", lambda: FakeStub())
    result = runner.invoke(cli.app, ["kb", "search", "billing"])

    assert result.exit_code == 0
    assert "/docs/billing.md" in result.stdout


def test_rpc_error_exits_nonzero_without_traceback(monkeypatch) -> None:
    class FailingStub:
        def Ask(self, _req: core_pb2.AskRequest) -> core_pb2.AskResponse:
            raise grpc.RpcError

    monkeypatch.setattr(cli, "_stub", lambda: FailingStub())
    result = runner.invoke(cli.app, ["ask", "anything"])

    assert result.exit_code == 1
    assert "error" in result.stdout.lower()


@pytest.mark.integration
def test_e2e_ask_against_live_kernel() -> None:
    # Requires a live kernel Core API (SWARM_CORE_ADDR) with an ingested corpus.
    result = runner.invoke(cli.app, ["ask", "find files related to architecture", "-s", "private"])
    assert result.exit_code == 0
    assert "tier=" in result.stdout
