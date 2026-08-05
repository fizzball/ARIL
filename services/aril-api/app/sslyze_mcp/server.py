"""MCP Streamable HTTP server exposing the local sslyze CLI as TLS/cert tools.

Implements just enough of the MCP JSON-RPC wire protocol (initialize,
tools/list, tools/call) to interoperate with ARIL's MCP client. Scans stream
progress over SSE; the final frame is the JSON-RPC result. Bearer-authenticated.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import AsyncIterator
from typing import Any

from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

from app.sslyze_mcp.config import SSLyzeMCPConfig
from app.sslyze_mcp.scanner import SSLyzeNotFoundError, SSLyzeScanner

_PROTOCOL_VERSION = "2024-11-05"
_SERVER_INFO = {"name": "aril-sslyze", "version": "1.0.0"}

_TARGET_SCHEMA = {
    "type": "object",
    "properties": {
        "target": {
            "type": "string",
            "description": (
                "Hostname, host:port, or https URL to scan "
                "(e.g. example.com, example.com:443, https://example.com)."
            ),
        }
    },
    "required": ["target"],
}

_CUSTOM_SCHEMA = {
    "type": "object",
    "properties": {
        "target": {
            "type": "string",
            "description": "Hostname, host:port, or https URL to scan.",
        },
        "args": {
            "type": "string",
            "description": (
                "Raw SSLyze flags excluding the binary and target "
                "(e.g. '--certinfo --http_headers' or '--tlsv1_3 --elliptic_curves')."
            ),
        },
    },
    "required": ["target", "args"],
}

_TOOLS = [
    {
        "name": "sslyze_cert_info",
        "description": (
            "Analyse the TLS certificate presented by a target: subject, issuer, "
            "validity dates, SANs, key type, and trust-store validation."
        ),
        "inputSchema": _TARGET_SCHEMA,
    },
    {
        "name": "sslyze_scan",
        "description": (
            "Full TLS posture scan against Mozilla's intermediate recommended "
            "configuration (protocols, ciphers, certificate, common checks)."
        ),
        "inputSchema": _TARGET_SCHEMA,
    },
    {
        "name": "sslyze_protocols",
        "description": (
            "Check which SSL/TLS protocol versions the target supports "
            "(SSLv2 through TLS 1.3) and accepted cipher suites."
        ),
        "inputSchema": _TARGET_SCHEMA,
    },
    {
        "name": "sslyze_vuln_checks",
        "description": (
            "Check classic TLS vulnerabilities: Heartbleed, OpenSSL CCS injection, "
            "ROBOT, CRIME (compression), and TLS_FALLBACK_SCSV."
        ),
        "inputSchema": _TARGET_SCHEMA,
    },
    {
        "name": "sslyze_custom_scan",
        "description": (
            "Run SSLyze with arbitrary flags for advanced TLS checks. "
            "Provide flags in 'args' and the host in 'target'."
        ),
        "inputSchema": _CUSTOM_SCHEMA,
    },
]

_TOOL_KINDS = {
    "sslyze_cert_info": "cert",
    "sslyze_scan": "scan",
    "sslyze_protocols": "protocols",
    "sslyze_vuln_checks": "heartbleed",
    "sslyze_custom_scan": "custom",
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
    """Keep informative sslyze stderr / warning lines worth streaming."""
    low = line.lower()
    keywords = (
        "scanning",
        "checking",
        "connecting",
        "certificate",
        "tls",
        "ssl",
        "error",
        "warning",
        "vulnerable",
        "completed",
    )
    if any(k in low for k in keywords):
        return line
    return None


async def _scan_stream(
    scanner: SSLyzeScanner, name: str, arguments: dict[str, Any], rpc_id: Any
) -> AsyncIterator[str]:
    """SSE generator: live `progress` frames, then a final JSON-RPC `result` frame."""
    kind = _TOOL_KINDS.get(name)
    if kind is None:
        yield _sse_result(rpc_id, _content_result(f"Unknown tool: {name}", is_error=True))
        return

    try:
        plan = scanner.build_plan(
            kind,
            target=str(arguments.get("target") or ""),
            extra=(str(arguments["args"]) if arguments.get("args") is not None else None),
        )
    except (SSLyzeNotFoundError, ValueError) as exc:
        yield _sse_result(rpc_id, _content_result(str(exc), is_error=True))
        return

    yield _sse_progress(f"Starting {name} on {plan.target_label}…")

    try:
        raw_json = ""
        async for event, payload in scanner.run_streaming(
            plan.command, json_out_path=plan.json_out_path
        ):
            if event == "progress":
                note = _progress_note(payload)
                if note:
                    yield _sse_progress(note)
            else:
                raw_json = payload
        summary = scanner.summarize(raw_json)
        yield _sse_result(rpc_id, _content_result(summary, is_error=False))
    except (SSLyzeNotFoundError, RuntimeError) as exc:
        yield _sse_result(rpc_id, _content_result(str(exc), is_error=True))


def build_app(config: SSLyzeMCPConfig) -> FastAPI:
    app = FastAPI(title="ARIL SSLyze MCP", version=_SERVER_INFO["version"])
    scanner = SSLyzeScanner(
        sslyze_path=config.sslyze_path,
        scan_timeout=config.scan_timeout,
    )
    mcp_path = config.normalized_path

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "service": "aril-sslyze-mcp",
            "sslyze_installed": scanner.resolve_binary() is not None,
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

    config = SSLyzeMCPConfig.load(config_path)
    app = build_app(config)
    uvicorn.run(app, host=config.host, port=config.port, log_level="warning")


def main() -> None:
    parser = argparse.ArgumentParser(description="ARIL managed SSLyze TLS/cert MCP server")
    parser.add_argument("-c", "--config", default=None, help="Path to config.json")
    args = parser.parse_args()
    run(args.config)


if __name__ == "__main__":
    main()
