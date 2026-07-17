"""MCP Streamable HTTP server exposing the local nmap binary as tools.

Implements just enough of the MCP JSON-RPC wire protocol (initialize,
tools/list, tools/call) to interoperate with ARIL's MCP client. Responses are
returned as `application/json`; the endpoint is bearer-authenticated.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import AsyncIterator
from typing import Any

from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

from app.nmap_mcp.config import NmapMCPConfig
from app.nmap_mcp.scanner import NmapNotFoundError, NmapScanner

_PROTOCOL_VERSION = "2024-11-05"
_SERVER_INFO = {"name": "aril-nmap", "version": "1.0.0"}

_TARGET_SCHEMA = {
    "type": "object",
    "properties": {
        "target": {
            "type": "string",
            "description": "Host, IP, or CIDR range to scan (e.g. scanme.nmap.org, 192.168.1.0/24).",
        }
    },
    "required": ["target"],
}

_TARGET_PORTS_SCHEMA = {
    "type": "object",
    "properties": {
        "target": {"type": "string", "description": "Host, IP, or CIDR range to scan."},
        "ports": {
            "type": "string",
            "description": "Optional port list/range (e.g. '22,80,443' or '1-1024').",
        },
    },
    "required": ["target"],
}

_CUSTOM_SCHEMA = {
    "type": "object",
    "properties": {
        "args": {
            "type": "string",
            "description": "Raw nmap arguments and target (do NOT include 'nmap'). e.g. '-sS -p 80,443 example.com'.",
        }
    },
    "required": ["args"],
}

_TOOLS = [
    {
        "name": "nmap_quick_scan",
        "description": "Fast scan of the most common ~100 TCP ports (nmap -F -T4). Good first pass.",
        "inputSchema": _TARGET_SCHEMA,
    },
    {
        "name": "nmap_full_scan",
        "description": "Full TCP port scan (1-65535) with service/version detection (nmap -p- -sV). Slow.",
        "inputSchema": _TARGET_SCHEMA,
    },
    {
        "name": "nmap_service_scan",
        "description": "Service and version detection on given ports (nmap -sV).",
        "inputSchema": _TARGET_PORTS_SCHEMA,
    },
    {
        "name": "nmap_vuln_scan",
        "description": "Vulnerability scan using the nmap NSE 'vuln' script category — checks known CVEs and misconfigurations (nmap -sV --script vuln).",
        "inputSchema": _TARGET_PORTS_SCHEMA,
    },
    {
        "name": "nmap_custom_scan",
        "description": "Run nmap with arbitrary arguments for advanced scans. Provide flags + target in 'args'.",
        "inputSchema": _CUSTOM_SCHEMA,
    },
]

_TOOL_KINDS = {
    "nmap_quick_scan": "quick",
    "nmap_full_scan": "full",
    "nmap_service_scan": "service",
    "nmap_vuln_scan": "vuln",
    "nmap_custom_scan": "custom",
}


def _jsonrpc_result(rpc_id: Any, result: dict[str, Any]) -> JSONResponse:
    return JSONResponse({"jsonrpc": "2.0", "id": rpc_id, "result": result})


def _jsonrpc_error(rpc_id: Any, code: int, message: str) -> JSONResponse:
    return JSONResponse(
        {"jsonrpc": "2.0", "id": rpc_id, "error": {"code": code, "message": message}}
    )


def _content_result(text: str, *, is_error: bool) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def _sse_progress(note: str) -> str:
    return f"event: progress\ndata: {json.dumps({'note': note})}\n\n"


def _sse_result(rpc_id: Any, result: dict[str, Any]) -> str:
    frame = {"jsonrpc": "2.0", "id": rpc_id, "result": result}
    return f"event: result\ndata: {json.dumps(frame)}\n\n"


def _progress_note(line: str) -> str | None:
    """Keep only the informative nmap stderr lines worth streaming to the model."""
    low = line.lower()
    if "discovered open port" in low:
        return line
    if "% done" in low:  # `Stats: ... 45.00% done; ETC: ...`
        return line
    if line.startswith(("Starting Nmap", "Initiating", "Nmap done", "Completed")):
        return line
    if "scan report for" in low:
        return line
    return None


async def _scan_stream(
    scanner: NmapScanner, name: str, arguments: dict[str, Any], rpc_id: Any
) -> AsyncIterator[str]:
    """SSE generator: live `progress` frames, then a final JSON-RPC `result` frame."""
    kind = _TOOL_KINDS.get(name)
    if kind is None:
        yield _sse_result(rpc_id, _content_result(f"Unknown tool: {name}", is_error=True))
        return

    target = str(arguments.get("target", "")).strip()
    try:
        command = scanner.build_command(
            kind,
            target=target,
            ports=(str(arguments["ports"]) if arguments.get("ports") else None),
            extra=(str(arguments["args"]) if arguments.get("args") else None),
        )
    except (NmapNotFoundError, ValueError) as exc:
        yield _sse_result(rpc_id, _content_result(str(exc), is_error=True))
        return

    label = target or "custom scan"
    yield _sse_progress(f"Starting {name} on {label}…")

    try:
        raw_xml = ""
        async for event, payload in scanner.run_streaming(command):
            if event == "progress":
                note = _progress_note(payload)
                if note:
                    yield _sse_progress(note)
            else:
                raw_xml = payload
        summary = scanner.summarize(raw_xml)
        yield _sse_result(rpc_id, _content_result(summary, is_error=False))
    except (NmapNotFoundError, RuntimeError) as exc:
        yield _sse_result(rpc_id, _content_result(str(exc), is_error=True))


def build_app(config: NmapMCPConfig) -> FastAPI:
    app = FastAPI(title="ARIL Nmap MCP", version=_SERVER_INFO["version"])
    scanner = NmapScanner(nmap_path=config.nmap_path, scan_timeout=config.scan_timeout)
    mcp_path = config.normalized_path

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "service": "aril-nmap-mcp",
            "nmap_installed": scanner.resolve_binary() is not None,
        }

    def _authorized(authorization: str | None) -> bool:
        if not config.token:
            return True
        expected = f"Bearer {config.token}"
        return (authorization or "").strip() == expected

    @app.post(mcp_path)
    async def mcp_endpoint(
        request: Request,
        authorization: str | None = Header(default=None),
    ) -> Response:
        if not _authorized(authorization):
            return _jsonrpc_error(None, -32001, "Unauthorized — invalid bearer token.")

        try:
            payload = await request.json()
        except Exception:
            return _jsonrpc_error(None, -32700, "Parse error.")

        if not isinstance(payload, dict):
            return _jsonrpc_error(None, -32600, "Invalid request.")

        method = payload.get("method")
        rpc_id = payload.get("id")

        # Notifications carry no id and expect no body.
        if method == "notifications/initialized" or rpc_id is None:
            return Response(status_code=202)

        if method == "initialize":
            return _jsonrpc_result(
                rpc_id,
                {
                    "protocolVersion": _PROTOCOL_VERSION,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": _SERVER_INFO,
                },
            )

        if method == "tools/list":
            return _jsonrpc_result(rpc_id, {"tools": _TOOLS})

        if method == "tools/call":
            params = payload.get("params") or {}
            name = str(params.get("name", ""))
            arguments = params.get("arguments") or {}
            if not isinstance(arguments, dict):
                arguments = {}
            # Scans stream progress over SSE; the last frame is the JSON-RPC result.
            return StreamingResponse(
                _scan_stream(scanner, name, arguments, rpc_id),
                media_type="text/event-stream",
                headers={
                    "Cache-Control": "no-cache",
                    "Connection": "keep-alive",
                    "X-Accel-Buffering": "no",
                },
            )

        return _jsonrpc_error(rpc_id, -32601, f"Method not found: {method}")

    return app


def run(config_path: str | None = None) -> None:
    import uvicorn

    config = NmapMCPConfig.load(config_path)
    app = build_app(config)
    uvicorn.run(app, host=config.host, port=config.port, log_level="warning")


def main() -> None:
    parser = argparse.ArgumentParser(description="ARIL managed Nmap MCP server")
    parser.add_argument("-c", "--config", default=None, help="Path to config.json")
    args = parser.parse_args()
    run(args.config)


if __name__ == "__main__":
    main()
