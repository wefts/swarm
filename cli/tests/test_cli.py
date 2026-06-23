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


def test_ask_renders_status_label_from_structured_field(monkeypatch) -> None:
    # T7: the channel renders the result-algebra STATUS from the structured field,
    # not by parsing the answer prose. A NOT_FOUND shows a deterministic label.
    class FakeStub:
        def Ask(self, _req: core_pb2.AskRequest) -> core_pb2.AskResponse:
            # answer prose deliberately has NO status words, so a match on the
            # label proves it came from the structured field, not the prose.
            return core_pb2.AskResponse(
                answer="(no matches in scope)",
                confidence=0.3,
                tier="tier_tools",
                status=core_pb2.NOT_FOUND,
            )

    monkeypatch.setattr(cli, "_stub", lambda: FakeStub())
    result = runner.invoke(cli.app, ["ask", "missing thing"])

    assert result.exit_code == 0
    assert "status: not found" in result.stdout.lower()


def test_ask_renders_value_verbatim_not_model_chosen(monkeypatch) -> None:
    # T7 determinism: an id/link is rendered EXACTLY from the structured citation
    # field — the channel formats it; the model never reformats the value.
    class FakeStub:
        def Ask(self, _req: core_pb2.AskRequest) -> core_pb2.AskResponse:
            return core_pb2.AskResponse(
                answer="see the ticket",
                confidence=0.7,
                tier="tier_tools",
                status=core_pb2.FOUND,
                citations=[
                    core_pb2.Citation(source="glpi", ref="GLPI-1234-billing", confidence=0.9)
                ],
            )

    monkeypatch.setattr(cli, "_stub", lambda: FakeStub())
    result = runner.invoke(cli.app, ["ask", "the ticket"])

    assert result.exit_code == 0
    # the exact structured value, rendered by the channel (not a model paraphrase)
    assert "GLPI-1234-billing" in result.stdout


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


def test_ask_passes_viewer_through(monkeypatch) -> None:
    # T8: the channel resolves identity and passes it; the kernel uses it.
    captured: dict[str, str] = {}

    class FakeStub:
        def Ask(self, req: core_pb2.AskRequest) -> core_pb2.AskResponse:
            captured["viewer"] = req.viewer
            return core_pb2.AskResponse(
                answer="ok", confidence=0.7, tier="tier_tools", status=core_pb2.FOUND
            )

    monkeypatch.setattr(cli, "_stub", lambda: FakeStub())
    result = runner.invoke(cli.app, ["ask", "my ticket", "--viewer", "alice"])

    assert result.exit_code == 0
    assert captured["viewer"] == "alice"


def test_status_renders_self_model(monkeypatch) -> None:
    # T8: the self-model (inventory, freshness, capabilities) renders from state.
    class FakeStub:
        def KbStatus(self, _req: core_pb2.StatusRequest) -> core_pb2.StatusResponse:
            return core_pb2.StatusResponse(
                nodes=3,
                edges=1,
                last_activity="2026-01-01T00:00:00Z",
                inventory=[core_pb2.TypeCount(type="file", count=2)],
                capabilities=["consilium:4-model-panel"],
            )

    monkeypatch.setattr(cli, "_stub", lambda: FakeStub())
    result = runner.invoke(cli.app, ["kb", "status"])

    assert result.exit_code == 0
    assert "file" in result.stdout
    assert "consilium" in result.stdout
    assert "last_activity" in result.stdout


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
