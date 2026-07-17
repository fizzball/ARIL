"""Tests for MCP tool sessions and OpenAI tool mapping."""

from __future__ import annotations

import json
from unittest.mock import AsyncMock

import httpx
import pytest
import respx

from app.mcp.client import (
    MCPSession,
    mcp_tools_to_openai,
    namespace_tool,
    server_slug,
    split_namespaced_tool,
)
from app.mcp.tool_loop import MCPServerSpec, open_mcp_bundle, run_mcp_tool_rounds
from app.providers.base import ProviderMessage, ProviderResult


def test_namespace_helpers():
    assert server_slug("DeepWiki") == "deepwiki"
    assert namespace_tool("deepwiki", "ask_question") == "deepwiki__ask_question"
    assert split_namespaced_tool("deepwiki__ask_question") == ("deepwiki", "ask_question")
    assert split_namespaced_tool("nope") is None


def test_mcp_tools_to_openai():
    tools = mcp_tools_to_openai(
        [
            {
                "name": "ask_question",
                "description": "Ask the wiki",
                "inputSchema": {
                    "type": "object",
                    "properties": {"repoName": {"type": "string"}},
                    "required": ["repoName"],
                },
            }
        ],
        server_slug="deepwiki",
    )
    assert len(tools) == 1
    assert tools[0]["type"] == "function"
    assert tools[0]["function"]["name"] == "deepwiki__ask_question"
    assert tools[0]["function"]["parameters"]["type"] == "object"


@pytest.mark.asyncio
@respx.mock
async def test_mcp_session_call_tool():
    url = "https://mcp.example.com/mcp"

    def init_response(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}},
            headers={"mcp-session-id": "sess-1"},
        )

    def call_response(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content.decode())
        assert body["method"] == "tools/call"
        assert body["params"]["name"] == "ask_question"
        assert request.headers.get("mcp-session-id") == "sess-1"
        return httpx.Response(
            200,
            json={
                "jsonrpc": "2.0",
                "id": 3,
                "result": {
                    "content": [{"type": "text", "text": "wiki answer"}],
                },
            },
        )

    respx.post(url).mock(
        side_effect=[
            init_response,
            httpx.Response(200, json={}),  # initialized
            call_response,
        ]
    )

    async with MCPSession(url=url, auth_style="none", label="DeepWiki", slug="deepwiki") as session:
        text = await session.call_tool("ask_question", {"repoName": "foo/bar"})
    assert text == "wiki answer"


@pytest.mark.asyncio
@respx.mock
async def test_call_tool_streams_sse_progress():
    """SSE tool responses should surface progress notes and the final result."""
    url = "https://nmap.local/mcp"

    def init_response(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}},
            headers={"mcp-session-id": "sess-1"},
        )

    sse_body = (
        'event: progress\ndata: {"note": "Discovered open port 80/tcp"}\n\n'
        'event: progress\ndata: {"note": "50.00% done"}\n\n'
        'event: result\ndata: {"jsonrpc":"2.0","id":3,'
        '"result":{"content":[{"type":"text","text":"scan summary"}]}}\n\n'
    )
    call_response = httpx.Response(
        200, headers={"content-type": "text/event-stream"}, content=sse_body
    )

    respx.post(url).mock(
        side_effect=[init_response, httpx.Response(200, json={}), call_response]
    )

    notes: list[str] = []

    async def on_progress(note: str) -> None:
        notes.append(note)

    async with MCPSession(url=url, auth_style="none", label="Nmap", slug="nmap") as session:
        text = await session.call_tool(
            "nmap_quick_scan", {"target": "scanme.nmap.org"}, on_progress=on_progress
        )

    assert text == "scan summary"
    assert "Discovered open port 80/tcp" in notes
    assert "50.00% done" in notes


@pytest.mark.asyncio
async def test_nmap_scan_stream_frames():
    """The nmap server's SSE generator emits progress then a JSON-RPC result."""
    from app.nmap_mcp import server as nmap_server

    class _FakeScanner:
        def build_command(self, kind, *, target, ports, extra):
            return ["nmap", "-x", target]

        async def run_streaming(self, command):
            yield ("progress", "Discovered open port 22/tcp on host")
            yield ("progress", "43.00% done; ETC: 12:00")
            yield ("result", "<nmaprun/>")

        def summarize(self, xml_output):
            return "SUMMARY"

    frames = [
        frame
        async for frame in nmap_server._scan_stream(
            _FakeScanner(), "nmap_quick_scan", {"target": "host"}, 7
        )
    ]
    joined = "".join(frames)
    assert "event: progress" in joined
    assert "22/tcp" in joined
    assert '"result"' in joined
    assert "SUMMARY" in joined
    # The last frame must be the JSON-RPC result (id echoed back).
    assert '"id": 7' in frames[-1]


@pytest.mark.asyncio
async def test_codescan_scan_stream_frames():
    """The codescan server's SSE generator emits progress then a JSON-RPC result."""
    from app.codescan_mcp import server as code_server
    from app.codescan_mcp.scanner import ScanPlan

    class _FakeScanner:
        def build_plan(self, kind, *, path=None, code=None, filename=None, rule=None, config=None):
            return ScanPlan(command=["semgrep", "scan"], target_label="app.py")

        async def run_streaming(self, command):
            yield ("progress", "Scanning 1 file with 3 rules")
            yield ("progress", "Ran 3 rules on 1 file: 1 finding")
            yield ("result", '{"results": []}')

        def summarize(self, json_output):
            return "CODE-SUMMARY"

    frames = [
        frame
        async for frame in code_server._scan_stream(
            _FakeScanner(), "semgrep_scan", {"code": "x = 1", "filename": "app.py"}, 9
        )
    ]
    joined = "".join(frames)
    assert "event: progress" in joined
    assert "Scanning 1 file" in joined
    assert '"result"' in joined
    assert "CODE-SUMMARY" in joined
    # The last frame must be the JSON-RPC result (id echoed back).
    assert '"id": 9' in frames[-1]


@pytest.mark.asyncio
async def test_codescan_scan_stream_reports_build_error():
    """A missing path/code yields a single error result frame (no crash)."""
    from app.codescan_mcp import server as code_server
    from app.codescan_mcp.scanner import SemgrepScanner

    frames = [
        frame
        async for frame in code_server._scan_stream(
            SemgrepScanner(), "semgrep_scan", {}, 3
        )
    ]
    joined = "".join(frames)
    assert '"isError": true' in joined
    assert '"id": 3' in frames[-1]


@pytest.mark.asyncio
@respx.mock
async def test_run_mcp_tool_rounds_executes_tool_then_answers():
    url = "https://mcp.example.com/mcp"

    def route(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content.decode())
        method = body.get("method")
        if method == "initialize":
            return httpx.Response(
                200,
                json={"jsonrpc": "2.0", "id": body["id"], "result": {}},
                headers={"mcp-session-id": "s1"},
            )
        if method == "notifications/initialized":
            return httpx.Response(200, json={})
        if method == "tools/list":
            return httpx.Response(
                200,
                json={
                    "jsonrpc": "2.0",
                    "id": body["id"],
                    "result": {
                        "tools": [
                            {
                                "name": "ask_question",
                                "description": "Ask",
                                "inputSchema": {"type": "object", "properties": {}},
                            }
                        ]
                    },
                },
            )
        if method == "tools/call":
            return httpx.Response(
                200,
                json={
                    "jsonrpc": "2.0",
                    "id": body["id"],
                    "result": {"content": [{"type": "text", "text": "tool-out"}]},
                },
            )
        return httpx.Response(500, text="unexpected")

    respx.post(url).mock(side_effect=route)

    bundle = await open_mcp_bundle(
        [MCPServerSpec(id="1", name="DeepWiki", url=url, auth_style="none")]
    )
    try:
        assert any(
            t["function"]["name"] == "deepwiki__ask_question" for t in bundle.openai_tools
        )

        provider = AsyncMock()
        provider.complete = AsyncMock(
            side_effect=[
                ProviderResult(
                    content="",
                    model="test/model",
                    input_tokens=10,
                    output_tokens=5,
                    cost_usd=0.01,
                    tool_calls=[
                        {
                            "id": "call_1",
                            "type": "function",
                            "function": {
                                "name": "deepwiki__ask_question",
                                "arguments": '{"q":"hi"}',
                            },
                        }
                    ],
                    finish_reason="tool_calls",
                ),
                ProviderResult(
                    content="Final answer from tools",
                    model="test/model",
                    input_tokens=20,
                    output_tokens=8,
                    cost_usd=0.02,
                ),
            ]
        )

        statuses: list[dict[str, str]] = []

        async def on_status(evt: dict[str, str]) -> None:
            statuses.append(evt)

        messages = [ProviderMessage(role="user", content="Use DeepWiki")]
        _, result = await run_mcp_tool_rounds(
            provider,
            messages,
            model="test/model",
            temperature=0.2,
            web_search=False,
            generate_image=False,
            bundle=bundle,
            on_status=on_status,
        )
        assert result.content == "Final answer from tools"
        assert result.input_tokens == 30
        assert any(s["phase"] == "calling" and s["tool"] == "ask_question" for s in statuses)
        assert provider.complete.await_count == 2
        # Second complete should include a tool role message
        second_msgs = provider.complete.await_args_list[1].args[0]
        assert any(m.role == "tool" and "tool-out" in m.content for m in second_msgs)
    finally:
        from app.mcp.tool_loop import close_mcp_bundle

        await close_mcp_bundle(bundle)
