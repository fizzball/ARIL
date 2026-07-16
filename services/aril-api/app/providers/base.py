from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from dataclasses import dataclass

from app.core.config import settings


@dataclass
class ProviderMessage:
    role: str
    content: str = ""
    # OpenAI-style multimodal parts when set (overrides plain content for API payload)
    parts: list[dict] | None = None
    # Assistant tool_calls (OpenAI format) or tool-role linkage
    tool_calls: list[dict] | None = None
    tool_call_id: str | None = None


@dataclass
class ProviderResult:
    content: str
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    cached: bool = False
    tool_calls: list[dict] | None = None
    finish_reason: str | None = None


@dataclass
class StreamChunk:
    content: str = ""
    model: str | None = None
    finish_reason: str | None = None
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0
    done: bool = False


class LLMProvider(ABC):
    name: str

    @abstractmethod
    async def complete(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
        web_search: bool = False,
        generate_image: bool = False,
        tools: list[dict] | None = None,
        tool_choice: str | None = None,
    ) -> ProviderResult:
        raise NotImplementedError

    async def stream(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
        web_search: bool = False,
        generate_image: bool = False,
        tools: list[dict] | None = None,
        tool_choice: str | None = None,
    ) -> AsyncIterator[StreamChunk]:
        """Default: emit the full completion as a single chunk."""
        result = await self.complete(
            messages,
            model=model,
            temperature=temperature,
            web_search=web_search,
            generate_image=generate_image,
            tools=tools,
            tool_choice=tool_choice,
        )
        if result.content:
            yield StreamChunk(content=result.content, model=result.model)
        yield StreamChunk(
            model=result.model,
            input_tokens=result.input_tokens,
            output_tokens=result.output_tokens,
            cost_usd=result.cost_usd,
            done=True,
        )


class StubProvider(LLMProvider):
    """Offline placeholder when no OpenRouter key is configured."""

    name = "stub"

    async def complete(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
        web_search: bool = False,
        generate_image: bool = False,
        tools: list[dict] | None = None,
        tool_choice: str | None = None,
    ) -> ProviderResult:
        last_user = next((m.content for m in reversed(messages) if m.role == "user"), "")
        web = " · web" if web_search else ""
        img = " · image" if generate_image else ""
        tool_note = f" · tools={len(tools)}" if tools else ""
        reply = (
            f"[ARIL stub · {model} · temp={temperature:.2f}{web}{img}{tool_note}]\n\n"
            f"Received your prompt ({len(last_user)} chars). "
            "Set OPENROUTER_API_KEY to enable live multi-model routing."
        )
        in_tok = max(1, len(last_user) // 4)
        out_tok = max(1, len(reply) // 4)
        return ProviderResult(
            content=reply,
            model=model,
            input_tokens=in_tok,
            output_tokens=out_tok,
            cost_usd=round((in_tok + out_tok) * 0.000002, 6),
            cached=False,
        )


def get_chat_provider() -> LLMProvider:
    """Prefer OpenRouter for single-key multi-model switching; else stub."""
    if settings.openrouter_api_key.strip():
        from app.providers.openrouter import OpenRouterProvider

        return OpenRouterProvider()
    return StubProvider()
