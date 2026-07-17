"""MCP Streamable HTTP server exposing the local semgrep CLI as code-scan tools.

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

from app.codescan_mcp.config import CodeScanMCPConfig
from app.codescan_mcp.scanner import SemgrepNotFoundError, SemgrepScanner

_PROTOCOL_VERSION = "2024-11-05"
_SERVER_INFO = {"name": "aril-codescan", "version": "1.0.0"}

_SCAN_SCHEMA = {
    "type": "object",
    "properties": {
        "path": {
            "type": "string",
            "description": "Absolute path to a file or directory on disk to scan.",
        },
        "code": {
            "type": "string",
            "description": "Inline source code to scan (used when 'path' is omitted).",
        },
        "filename": {
            "type": "string",
            "description": "Filename for inline 'code' so semgrep detects the language (e.g. app.py, index.js).",
        },
        "config": {
            "type": "string",
            "description": "Optional Semgrep ruleset (e.g. 'auto', 'p/security-audit', 'p/owasp-top-ten').",
        },
    },
}

_SECURITY_SCHEMA = {
    "type": "object",
    "properties": {
        "path": {"type": "string", "description": "Absolute path to a file or directory to scan."},
        "code": {"type": "string", "description": "Inline source code to scan (used when 'path' is omitted)."},
        "filename": {"type": "string", "description": "Filename for inline 'code' so semgrep detects the language."},
    },
}

_CUSTOM_SCHEMA = {
    "type": "object",
    "properties": {
        "rule": {
            "type": "string",
            "description": "A full Semgrep rule in YAML (with a top-level 'rules:' list).",
        },
        "path": {"type": "string", "description": "Absolute path to a file or directory to scan."},
        "code": {"type": "string", "description": "Inline source code to scan (used when 'path' is omitted)."},
        "filename": {"type": "string", "description": "Filename for inline 'code' so semgrep detects the language."},
    },
    "required": ["rule"],
}

_TOOLS = [
    {
        "name": "semgrep_scan",
        "description": "Static analysis of code with Semgrep. Scans a file/directory path or inline code and returns findings. Defaults to the 'auto' ruleset; override via 'config'.",
        "inputSchema": _SCAN_SCHEMA,
    },
    {
        "name": "security_check",
        "description": "Security-focused Semgrep scan (p/security-audit ruleset) over a path or inline code. Good first pass for vulnerabilities.",
        "inputSchema": _SECURITY_SCHEMA,
    },
    {
        "name": "semgrep_scan_with_custom_rule",
        "description": "Run a user-provided Semgrep rule (YAML) against a path or inline code. Use for targeted checks without the registry.",
        "inputSchema": _CUSTOM_SCHEMA,
    },
]

_TOOL_KINDS = {
    "semgrep_scan": "scan",
    "security_check": "security",
    "semgrep_scan_with_custom_rule": "custom",
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
    """Keep only the informative semgrep stderr lines worth streaming."""
    low = line.lower()
    keywords = (
        "scanning",
        "rules",
        "ran ",
        "findings",
        "downloading",
        "loading",
        "fetching",
        "parsing",
        "scan",
    )
    if any(k in low for k in keywords):
        return line
    return None


async def _scan_stream(
    scanner: SemgrepScanner, name: str, arguments: dict[str, Any], rpc_id: Any
) -> AsyncIterator[str]:
    """SSE generator: live `progress` frames, then a final JSON-RPC `result` frame."""
    kind = _TOOL_KINDS.get(name)
    if kind is None:
        yield _sse_result(rpc_id, _content_result(f"Unknown tool: {name}", is_error=True))
        return

    try:
        plan = scanner.build_plan(
            kind,
            path=(str(arguments["path"]) if arguments.get("path") else None),
            code=(str(arguments["code"]) if arguments.get("code") else None),
            filename=(str(arguments["filename"]) if arguments.get("filename") else None),
            rule=(str(arguments["rule"]) if arguments.get("rule") else None),
            config=(str(arguments["config"]) if arguments.get("config") else None),
        )
    except (SemgrepNotFoundError, ValueError) as exc:
        yield _sse_result(rpc_id, _content_result(str(exc), is_error=True))
        return

    yield _sse_progress(f"Starting {name} on {plan.target_label}…")

    try:
        raw_json = ""
        async for event, payload in scanner.run_streaming(plan.command):
            if event == "progress":
                note = _progress_note(payload)
                if note:
                    yield _sse_progress(note)
            else:
                raw_json = payload
        summary = scanner.summarize(raw_json)
        yield _sse_result(rpc_id, _content_result(summary, is_error=False))
    except (SemgrepNotFoundError, RuntimeError) as exc:
        yield _sse_result(rpc_id, _content_result(str(exc), is_error=True))
    finally:
        plan.cleanup()


def build_app(config: CodeScanMCPConfig) -> FastAPI:
    app = FastAPI(title="ARIL Code Scan MCP", version=_SERVER_INFO["version"])
    scanner = SemgrepScanner(
        semgrep_path=config.semgrep_path,
        default_config=config.default_config,
        scan_timeout=config.scan_timeout,
    )
    mcp_path = config.normalized_path

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "service": "aril-codescan-mcp",
            "semgrep_installed": scanner.resolve_binary() is not None,
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

    config = CodeScanMCPConfig.load(config_path)
    app = build_app(config)
    uvicorn.run(app, host=config.host, port=config.port, log_level="warning")


def main() -> None:
    parser = argparse.ArgumentParser(description="ARIL managed Semgrep code-scan MCP server")
    parser.add_argument("-c", "--config", default=None, help="Path to config.json")
    args = parser.parse_args()
    run(args.config)


if __name__ == "__main__":
    main()
