"""Swarm CLI channel (Domain 11): a thin client over the kernel Core API.

Renders answers and accepts input; the kernel owns cognition and the single
voice. Style: no emoji, semantic color, left-aligned, Rich tables.
"""

from __future__ import annotations

import os
from typing import Annotated

import grpc
import typer
from rich.box import SIMPLE_HEAD
from rich.console import Console
from rich.table import Table

from swarm_cli._gen import core_pb2, core_pb2_grpc

app = typer.Typer(help="Swarm — ask the knowledge base via the kernel Core API.")
kb_app = typer.Typer(help="Knowledge-base inspection.")
app.add_typer(kb_app, name="kb")

_console = Console()

ScopeOpt = Annotated[
    list[str] | None, typer.Option("--scope", "-s", help="Allowed visibility scopes")
]


def _stub() -> core_pb2_grpc.CoreStub:
    addr = os.environ.get("SWARM_CORE_ADDR", "127.0.0.1:50061")
    return core_pb2_grpc.CoreStub(grpc.insecure_channel(addr))


def _confidence_style(confidence: float) -> str:
    if confidence >= 0.7:
        return "green"
    if confidence >= 0.4:
        return "yellow"
    return "red"


def _fail(err: grpc.RpcError) -> None:
    code = err.code().name if isinstance(err, grpc.Call) else "UNKNOWN"
    _console.print(f"error: core API call failed ({code})", style="red")
    raise typer.Exit(code=1) from None


@app.command()
def ask(question: str, scope: ScopeOpt = None) -> None:
    """Ask a question; the kernel routes it and answers with citations."""
    try:
        resp = _stub().Ask(core_pb2.AskRequest(query=question, scopes=scope or ["public"]))
    except grpc.RpcError as err:
        _fail(err)
        return

    _console.print(resp.answer)
    if resp.citations:
        table = Table(box=SIMPLE_HEAD)
        table.add_column("Source")
        table.add_column("Reference")
        table.add_column("Confidence")
        for c in resp.citations:
            table.add_row(c.source, c.ref, f"{c.confidence:.2f}")
        _console.print(table)

    _console.print(
        f"tier={resp.tier} confidence={resp.confidence:.2f}",
        style=_confidence_style(resp.confidence),
    )


@kb_app.command()
def status() -> None:
    """Show graph size and embedding-namespace stamps."""
    try:
        resp = _stub().KbStatus(core_pb2.StatusRequest())
    except grpc.RpcError as err:
        _fail(err)
        return

    _console.print(f"nodes={resp.nodes} edges={resp.edges}")
    table = Table(box=SIMPLE_HEAD)
    for col in ("Namespace", "Model", "Dim", "Status"):
        table.add_column(col)
    for s in resp.namespaces:
        table.add_row(s.namespace, s.model, str(s.dim), s.status)
    _console.print(table)


@kb_app.command()
def search(
    query: str,
    scope: ScopeOpt = None,
    limit: Annotated[int, typer.Option("--limit", "-n", help="Max hits")] = 10,
) -> None:
    """Retrieve matching nodes from the graph (scope-filtered)."""
    try:
        resp = _stub().KbSearch(
            core_pb2.SearchRequest(query=query, scopes=scope or ["public"], limit=limit)
        )
    except grpc.RpcError as err:
        _fail(err)
        return

    table = Table(box=SIMPLE_HEAD)
    for col in ("Id", "Type", "Key", "Score"):
        table.add_column(col)
    for h in resp.hits:
        table.add_row(str(h.id), h.type, h.key, f"{h.score:.2f}")
    _console.print(table)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
