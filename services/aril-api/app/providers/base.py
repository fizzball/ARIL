from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class ProviderMessage:
    role: str
    content: str


@dataclass
class ProviderResult:
    content: str
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    cached: bool = False


class LLMProvider(ABC):
    name: str

    @abstractmethod
    async def complete(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
    ) -> ProviderResult:
        raise NotImplementedError


class StubProvider(LLMProvider):
    """Phase 0 placeholder — no external network calls."""

    name = "stub"

    async def complete(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
    ) -> ProviderResult:
        last_user = next((m.content for m in reversed(messages) if m.role == "user"), "")
        reply = (
            f"[ARIL stub · {model} · temp={temperature:.2f}]\n\n"
            f"Received your prompt ({len(last_user)} chars). "
            "Provider adapters will replace this echo in Phase 1."
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


# Registry placeholders for Phase 1+
PROVIDERS: dict[str, LLMProvider] = {
    "stub": StubProvider(),
}
