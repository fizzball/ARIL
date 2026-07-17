"""Gateway-side MCP ↔ OpenRouter tool loop for chat turns."""

from __future__ import annotations

import json
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from app.mcp.client import (
    MCPSession,
    mcp_tools_to_openai,
    server_slug,
    split_namespaced_tool,
)
from app.providers.base import LLMProvider, ProviderMessage, ProviderResult

MAX_TOOL_ROUNDS = 5

StatusCallback = Callable[[dict[str, str]], Awaitable[None]]


@dataclass
class MCPServerSpec:
    id: str
    name: str
    url: str
    auth_style: str = "bearer"
    auth_header_name: str | None = None
    api_key: str | None = None


@dataclass
class MCPToolBundle:
    openai_tools: list[dict[str, Any]]
    sessions: dict[str, MCPSession]  # slug → session
    display_names: dict[str, str]  # slug → label


async def open_mcp_bundle(servers: list[MCPServerSpec]) -> MCPToolBundle:
    """Connect to each server and collect namespaced OpenAI tools."""
    sessions: dict[str, MCPSession] = {}
    display_names: dict[str, str] = {}
    openai_tools: list[dict[str, Any]] = []
    used_slugs: set[str] = set()

    try:
        for spec in servers:
            label = (spec.name or "").strip() or "MCP"
            base = server_slug(label, fallback=spec.id or "mcp")
            slug = base
            n = 2
            while slug in used_slugs:
                slug = f"{base}_{n}"
                n += 1
            used_slugs.add(slug)
            session = MCPSession(
                url=spec.url,
                auth_style=spec.auth_style,
                auth_header_name=spec.auth_header_name,
                api_key=spec.api_key,
                label=label,
                slug=slug,
            )
            await session.connect()
            tools = await session.list_tools()
            sessions[slug] = session
            display_names[slug] = label
            openai_tools.extend(mcp_tools_to_openai(tools, server_slug=slug))
    except Exception:
        for s in sessions.values():
            await s.aclose()
        raise

    return MCPToolBundle(
        openai_tools=openai_tools,
        sessions=sessions,
        display_names=display_names,
    )


async def close_mcp_bundle(bundle: MCPToolBundle | None) -> None:
    if not bundle:
        return
    for session in bundle.sessions.values():
        await session.aclose()


def _parse_tool_arguments(raw: Any) -> dict[str, Any]:
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return {}
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            return {"_raw": text}
        return obj if isinstance(obj, dict) else {"_raw": obj}
    return {"_raw": raw}


async def run_mcp_tool_rounds(
    provider: LLMProvider,
    messages: list[ProviderMessage],
    *,
    model: str,
    temperature: float,
    web_search: bool,
    generate_image: bool,
    bundle: MCPToolBundle,
    on_status: StatusCallback | None = None,
) -> tuple[list[ProviderMessage], ProviderResult]:
    """Run non-stream completions until a text answer (or max rounds).

    Mutates and returns the working message list (including tool turns).
    The final ProviderResult has no pending tool_calls.
    """
    if not bundle.openai_tools:
        result = await provider.complete(
            messages,
            model=model,
            temperature=temperature,
            web_search=web_search,
            generate_image=generate_image,
        )
        return messages, result

    working = list(messages)
    total_in = 0
    total_out = 0
    total_cost = 0.0
    last_model = model

    for _ in range(MAX_TOOL_ROUNDS):
        result = await provider.complete(
            working,
            model=model,
            temperature=temperature,
            web_search=web_search,
            generate_image=generate_image,
            tools=bundle.openai_tools,
            tool_choice="auto",
        )
        total_in += result.input_tokens
        total_out += result.output_tokens
        total_cost += result.cost_usd
        last_model = result.model or last_model

        tool_calls = result.tool_calls or []
        if not tool_calls:
            return working, ProviderResult(
                content=result.content,
                model=last_model,
                input_tokens=total_in,
                output_tokens=total_out,
                cost_usd=round(total_cost, 6),
                cached=False,
            )

        working.append(
            ProviderMessage(
                role="assistant",
                content=result.content or "",
                tool_calls=tool_calls,
            )
        )

        for call in tool_calls:
            if not isinstance(call, dict):
                continue
            call_id = str(call.get("id") or "")
            fn = call.get("function") if isinstance(call.get("function"), dict) else {}
            namespaced = str((fn or {}).get("name") or "")
            args = _parse_tool_arguments((fn or {}).get("arguments"))
            split = split_namespaced_tool(namespaced)
            if not split:
                tool_content = f"Unknown tool name: {namespaced}"
                server_label = "MCP"
                tool_name = namespaced or "unknown"
            else:
                slug, tool_name = split
                session = bundle.sessions.get(slug)
                server_label = bundle.display_names.get(slug, slug)
                if on_status:
                    await on_status(
                        {
                            "server": server_label,
                            "tool": tool_name,
                            "phase": "calling",
                        }
                    )
                if session is None:
                    tool_content = f"No MCP session for server '{slug}'."
                else:
                    progress_cb = None
                    if on_status is not None:
                        async def progress_cb(  # noqa: E731
                            note: str, _sl: str = server_label, _tn: str = tool_name
                        ) -> None:
                            await on_status(
                                {
                                    "server": _sl,
                                    "tool": _tn,
                                    "phase": "progress",
                                    "note": note,
                                }
                            )

                    try:
                        tool_content = await session.call_tool(
                            tool_name, args, on_progress=progress_cb
                        )
                    except RuntimeError as exc:
                        tool_content = f"Tool error: {exc}"
                if on_status:
                    await on_status(
                        {
                            "server": server_label,
                            "tool": tool_name,
                            "phase": "done",
                        }
                    )

            working.append(
                ProviderMessage(
                    role="tool",
                    content=tool_content,
                    tool_call_id=call_id or None,
                )
            )

    # Max rounds exhausted — one last completion without tools.
    final = await provider.complete(
        working,
        model=model,
        temperature=temperature,
        web_search=web_search,
        generate_image=generate_image,
    )
    return working, ProviderResult(
        content=final.content,
        model=final.model or last_model,
        input_tokens=total_in + final.input_tokens,
        output_tokens=total_out + final.output_tokens,
        cost_usd=round(total_cost + final.cost_usd, 6),
        cached=False,
    )
