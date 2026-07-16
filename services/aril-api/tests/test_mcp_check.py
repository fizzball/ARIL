"""Tests for MCP remote connection probe."""

from __future__ import annotations

import json

import httpx
import pytest
import respx

from app.mcp.client import check_remote_mcp


@pytest.mark.asyncio
@respx.mock
async def test_mcp_check_success_lists_tools():
    url = "https://mcp.example.com/mcp"

    def init_response(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content.decode())
        assert body["method"] == "initialize"
        assert request.headers.get("Authorization") == "Bearer secret-token"
        return httpx.Response(
            200,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "serverInfo": {"name": "example", "version": "1"},
                },
            },
            headers={"mcp-session-id": "sess-1"},
        )

    def tools_response(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content.decode())
        assert body["method"] == "tools/list"
        assert request.headers.get("mcp-session-id") == "sess-1"
        return httpx.Response(
            200,
            json={
                "jsonrpc": "2.0",
                "id": 2,
                "result": {
                    "tools": [
                        {"name": "alpha", "description": "A"},
                        {"name": "beta", "description": "B"},
                    ]
                },
            },
        )

    respx.post(url).mock(side_effect=[init_response, httpx.Response(200, json={}), tools_response])

    result = await check_remote_mcp(
        url=url,
        auth_style="bearer",
        api_key="secret-token",
    )
    assert result["ok"] is True
    assert result["tools_count"] == 2
    assert result["tool_names"] == ["alpha", "beta"]
    assert "Connected" in result["message"]


@pytest.mark.asyncio
@respx.mock
async def test_mcp_check_unauthorized():
    url = "https://mcp.example.com/mcp"
    respx.post(url).mock(return_value=httpx.Response(401, text="nope"))
    result = await check_remote_mcp(url=url, auth_style="bearer", api_key="bad")
    assert result["ok"] is False
    assert "Unauthorized" in result["message"]


@pytest.mark.asyncio
async def test_mcp_check_empty_url():
    result = await check_remote_mcp(url="  ", auth_style="none")
    assert result["ok"] is False
    assert "empty" in result["message"].lower()


@pytest.mark.asyncio
@respx.mock
async def test_mcp_check_header_auth():
    url = "https://mcp.example.com/mcp"

    def init_response(request: httpx.Request) -> httpx.Response:
        assert request.headers.get("X-ADM-API-Key") == "adm-key"
        return httpx.Response(
            200,
            json={"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}},
        )

    respx.post(url).mock(
        side_effect=[
            init_response,
            httpx.Response(200, json={}),
            httpx.Response(
                200,
                json={"jsonrpc": "2.0", "id": 2, "result": {"tools": []}},
            ),
        ]
    )
    result = await check_remote_mcp(
        url=url,
        auth_style="header",
        auth_header_name="X-ADM-API-Key",
        api_key="adm-key",
    )
    assert result["ok"] is True
