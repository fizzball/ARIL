"""Remote MCP Streamable HTTP client (check + chat tool sessions)."""

from __future__ import annotations

import json
import re
import time
from collections.abc import Awaitable, Callable
from typing import Any

import httpx

ProgressCallback = Callable[[str], Awaitable[None]]

_TIMEOUT = 15.0
_CALL_TIMEOUT = 30.0
_PROTOCOL = "2024-11-05"
_CLIENT_INFO = {"name": "aril", "version": "0.3.19"}


def _auth_headers(
    *,
    auth_style: str,
    auth_header_name: str | None,
    api_key: str | None,
) -> dict[str, str]:
    headers: dict[str, str] = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    key = (api_key or "").strip()
    style = (auth_style or "bearer").strip().lower()
    if style == "none" or not key:
        return headers
    if style == "header":
        name = (auth_header_name or "Authorization").strip() or "Authorization"
        headers[name] = key
        return headers
    headers["Authorization"] = f"Bearer {key}"
    return headers


def _parse_jsonrpc_payload(text: str) -> dict[str, Any] | None:
    """Parse a JSON-RPC object from raw JSON or SSE `data:` lines."""
    raw = (text or "").strip()
    if not raw:
        return None
    if raw.startswith("{"):
        try:
            obj = json.loads(raw)
            return obj if isinstance(obj, dict) else None
        except json.JSONDecodeError:
            pass
    last: dict[str, Any] | None = None
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            last = obj
    return last


def _rpc_error_message(payload: dict[str, Any] | None) -> str | None:
    if not payload:
        return None
    err = payload.get("error")
    if isinstance(err, dict):
        msg = err.get("message")
        if isinstance(msg, str) and msg.strip():
            return msg.strip()
        return "MCP server returned an error"
    return None


def server_slug(name: str, fallback: str = "mcp") -> str:
    """Stable OpenAI-safe namespace prefix for a server display name."""
    raw = (name or "").strip().lower()
    cleaned = re.sub(r"[^a-z0-9]+", "_", raw).strip("_")
    if not cleaned:
        cleaned = re.sub(r"[^a-z0-9]+", "_", (fallback or "mcp").lower()).strip("_")
    return (cleaned or "mcp")[:40]


def namespace_tool(slug: str, tool_name: str) -> str:
    return f"{slug}__{tool_name}"


def split_namespaced_tool(namespaced: str) -> tuple[str, str] | None:
    if "__" not in (namespaced or ""):
        return None
    slug, tool = namespaced.split("__", 1)
    if not slug or not tool:
        return None
    return slug, tool


def mcp_tools_to_openai(tools: list[dict[str, Any]], *, server_slug: str) -> list[dict[str, Any]]:
    """Map MCP tools/list entries to OpenAI Chat Completions `tools` entries."""
    out: list[dict[str, Any]] = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        if not isinstance(name, str) or not name.strip():
            continue
        description = tool.get("description")
        if not isinstance(description, str):
            description = ""
        schema = tool.get("inputSchema")
        if not isinstance(schema, dict):
            schema = {"type": "object", "properties": {}}
        out.append(
            {
                "type": "function",
                "function": {
                    "name": namespace_tool(server_slug, name.strip()),
                    "description": description.strip() or name.strip(),
                    "parameters": schema,
                },
            }
        )
    return out


def _tool_result_text(result: Any) -> str:
    """Flatten MCP tools/call result into a string for the model."""
    if result is None:
        return ""
    if isinstance(result, str):
        return result
    if isinstance(result, dict):
        is_error = bool(result.get("isError"))
        content = result.get("content")
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict):
                    item_type = item.get("type")
                    if item_type == "text" and isinstance(item.get("text"), str):
                        parts.append(item["text"])
                    elif item_type == "image":
                        # Base64 screenshots blow the context window.
                        parts.append("[screenshot image omitted]")
                    else:
                        parts.append(json.dumps(item, ensure_ascii=False))
                else:
                    parts.append(str(item))
            if parts:
                body = "\n".join(parts)
                return f"TOOL ERROR:\n{body}" if is_error else body
        raw = json.dumps(result, ensure_ascii=False)
        return f"TOOL ERROR:\n{raw}" if is_error else raw
    return json.dumps(result, ensure_ascii=False)


class MCPSession:
    """One remote MCP Streamable HTTP session (per chat turn)."""

    def __init__(
        self,
        *,
        url: str,
        auth_style: str = "bearer",
        auth_header_name: str | None = None,
        api_key: str | None = None,
        label: str = "",
        slug: str = "mcp",
    ) -> None:
        self.url = (url or "").strip()
        self.auth_style = auth_style
        self.auth_header_name = auth_header_name
        self.api_key = api_key
        self.label = (label or slug or "MCP").strip() or "MCP"
        self.slug = slug or server_slug(self.label)
        self._client: httpx.AsyncClient | None = None
        self._headers: dict[str, str] = {}
        self._rpc_id = 0

    async def __aenter__(self) -> MCPSession:
        await self.connect()
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    async def connect(self) -> None:
        if not self.url:
            raise RuntimeError("MCP server URL is empty.")
        if not self.url.startswith(("http://", "https://")):
            raise RuntimeError("MCP URL must start with http:// or https://.")
        headers = _auth_headers(
            auth_style=self.auth_style,
            auth_header_name=self.auth_header_name,
            api_key=self.api_key,
        )
        self._client = httpx.AsyncClient(timeout=_TIMEOUT, follow_redirects=True)
        init_body = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "initialize",
            "params": {
                "protocolVersion": _PROTOCOL,
                "capabilities": {},
                "clientInfo": _CLIENT_INFO,
            },
        }
        init_resp = await self._client.post(self.url, headers=headers, json=init_body)
        if init_resp.status_code in (401, 403):
            raise RuntimeError(
                f"Unauthorized ({init_resp.status_code}) — check API key / token."
            )
        if init_resp.status_code >= 400:
            detail = (init_resp.text or "").strip()
            if len(detail) > 160:
                detail = detail[:157] + "…"
            raise RuntimeError(
                f"{self.label}: HTTP {init_resp.status_code}"
                + (f": {detail}" if detail else ".")
            )
        init_payload = _parse_jsonrpc_payload(init_resp.text)
        if err := _rpc_error_message(init_payload):
            raise RuntimeError(f"{self.label}: {err}")

        session_headers = dict(headers)
        for key, value in init_resp.headers.items():
            lk = key.lower()
            if lk in ("mcp-session-id", "x-session-id") and value:
                session_headers[key] = value
        self._headers = session_headers

        try:
            await self._client.post(
                self.url,
                headers=self._headers,
                json={
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": {},
                },
            )
        except httpx.HTTPError:
            pass

    async def aclose(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    def _next_id(self) -> int:
        self._rpc_id += 1
        return self._rpc_id

    async def _rpc(self, method: str, params: dict[str, Any] | None = None) -> Any:
        if self._client is None:
            raise RuntimeError(f"{self.label}: MCP session is not connected.")
        body = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": method,
            "params": params or {},
        }
        timeout = _CALL_TIMEOUT if method == "tools/call" else _TIMEOUT
        try:
            resp = await self._client.post(
                self.url,
                headers=self._headers,
                json=body,
                timeout=timeout,
            )
        except httpx.TimeoutException as exc:
            raise RuntimeError(f"{self.label}: MCP {method} timed out.") from exc
        except httpx.HTTPError as exc:
            raise RuntimeError(
                f"{self.label}: MCP unreachable ({exc.__class__.__name__})."
            ) from exc
        if resp.status_code >= 400:
            detail = (resp.text or "").strip()
            if len(detail) > 160:
                detail = detail[:157] + "…"
            raise RuntimeError(
                f"{self.label}: HTTP {resp.status_code} on {method}"
                + (f": {detail}" if detail else ".")
            )
        payload = _parse_jsonrpc_payload(resp.text)
        if err := _rpc_error_message(payload):
            raise RuntimeError(f"{self.label}: {err}")
        if not isinstance(payload, dict):
            raise RuntimeError(f"{self.label}: empty MCP response for {method}.")
        return payload.get("result")

    async def list_tools(self) -> list[dict[str, Any]]:
        result = await self._rpc("tools/list", {})
        if not isinstance(result, dict):
            return []
        tools = result.get("tools")
        if not isinstance(tools, list):
            return []
        return [t for t in tools if isinstance(t, dict)]

    async def call_tool(
        self,
        name: str,
        arguments: dict[str, Any] | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> str:
        """Invoke a tool. If the server streams SSE, forward progress notes live.

        Works for both plain JSON responses (existing servers) and Streamable HTTP
        SSE responses (e.g. the managed Nmap server) that emit `progress` frames
        followed by a final JSON-RPC `result` frame.
        """
        if self._client is None:
            raise RuntimeError(f"{self.label}: MCP session is not connected.")
        body = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        }
        # No overall read timeout: streamed scans can run for minutes between the
        # connect and the final result frame; progress keeps the socket alive.
        timeout = httpx.Timeout(_TIMEOUT, read=None, write=_TIMEOUT, pool=_TIMEOUT)
        result: Any = None
        try:
            async with self._client.stream(
                "POST", self.url, headers=self._headers, json=body, timeout=timeout
            ) as resp:
                if resp.status_code >= 400:
                    detail = (await resp.aread()).decode("utf-8", "replace").strip()
                    if len(detail) > 160:
                        detail = detail[:157] + "…"
                    raise RuntimeError(
                        f"{self.label}: HTTP {resp.status_code} on tools/call"
                        + (f": {detail}" if detail else ".")
                    )
                ctype = resp.headers.get("content-type", "").lower()
                if "text/event-stream" in ctype:
                    result = await self._consume_sse_tool(resp, on_progress)
                else:
                    raw = (await resp.aread()).decode("utf-8", "replace")
                    payload = _parse_jsonrpc_payload(raw)
                    if err := _rpc_error_message(payload):
                        raise RuntimeError(f"{self.label}: {err}")
                    result = payload.get("result") if isinstance(payload, dict) else None
        except httpx.TimeoutException as exc:
            raise RuntimeError(f"{self.label}: MCP tools/call timed out.") from exc
        except httpx.HTTPError as exc:
            raise RuntimeError(
                f"{self.label}: MCP unreachable ({exc.__class__.__name__})."
            ) from exc

        text = _tool_result_text(result)
        if len(text) > 80_000:
            text = text[:79_997] + "…"
        return text

    async def _consume_sse_tool(
        self, resp: httpx.Response, on_progress: ProgressCallback | None
    ) -> Any:
        """Parse an SSE tool response, invoking on_progress per `note` frame."""
        data_lines: list[str] = []
        result: Any = None

        async def _flush() -> None:
            nonlocal result
            if not data_lines:
                return
            obj = None
            try:
                obj = json.loads("\n".join(data_lines))
            except json.JSONDecodeError:
                obj = None
            if isinstance(obj, dict):
                if "result" in obj:
                    result = obj["result"]
                elif "error" in obj:
                    err = _rpc_error_message(obj)
                    if err:
                        raise RuntimeError(f"{self.label}: {err}")
                elif "note" in obj and on_progress is not None:
                    note = str(obj["note"]).strip()
                    if note:
                        await on_progress(note)

        async for raw in resp.aiter_lines():
            line = raw.rstrip("\r")
            if line == "":
                await _flush()
                data_lines = []
                continue
            if line.startswith(":"):
                continue
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
        await _flush()
        return result


async def check_remote_mcp(
    *,
    url: str,
    auth_style: str = "bearer",
    auth_header_name: str | None = None,
    api_key: str | None = None,
) -> dict[str, Any]:
    """Probe a remote MCP endpoint. Never logs secrets."""
    target = (url or "").strip()
    checked_at = time.time()
    base: dict[str, Any] = {
        "ok": False,
        "tools_count": None,
        "tool_names": [],
        "latency_ms": None,
        "message": "",
        "checked_at": checked_at,
    }
    if not target:
        return {**base, "message": "MCP server URL is empty."}
    if not target.startswith(("http://", "https://")):
        return {**base, "message": "MCP URL must start with http:// or https://."}

    started = time.perf_counter()
    try:
        async with MCPSession(
            url=target,
            auth_style=auth_style,
            auth_header_name=auth_header_name,
            api_key=api_key,
            label="MCP",
            slug="mcp",
        ) as session:
            tools = await session.list_tools()
            latency_ms = int((time.perf_counter() - started) * 1000)
            names = [
                t["name"]
                for t in tools
                if isinstance(t.get("name"), str)
            ][:20]
            return {
                "ok": True,
                "tools_count": len(names) if names else len(tools),
                "tool_names": names,
                "latency_ms": latency_ms,
                "message": "Connected to MCP server.",
                "checked_at": checked_at,
            }
    except RuntimeError as exc:
        return {
            **base,
            "latency_ms": int((time.perf_counter() - started) * 1000),
            "message": str(exc),
        }
    except Exception as exc:  # noqa: BLE001
        return {
            **base,
            "latency_ms": int((time.perf_counter() - started) * 1000),
            "message": f"MCP check failed: {exc.__class__.__name__}",
        }
