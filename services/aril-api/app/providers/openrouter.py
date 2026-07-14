"""OpenRouter provider — single API for multi-model routing."""

from __future__ import annotations

import httpx

from app.core.config import settings
from app.providers.base import LLMProvider, ProviderMessage, ProviderResult


class OpenRouterProvider(LLMProvider):
    """OpenAI-compatible client against https://openrouter.ai/api/v1."""

    name = "openrouter"

    def __init__(
        self,
        *,
        api_key: str | None = None,
        base_url: str | None = None,
        site_url: str | None = None,
        app_name: str | None = None,
    ) -> None:
        self.api_key = api_key if api_key is not None else settings.openrouter_api_key
        self.base_url = (base_url or settings.openrouter_base_url).rstrip("/")
        self.site_url = site_url or settings.openrouter_site_url
        self.app_name = app_name or settings.openrouter_app_name

    async def complete(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
    ) -> ProviderResult:
        if not self.api_key:
            raise RuntimeError(
                "OPENROUTER_API_KEY is not set. Add it to services/aril-api/.env "
                "(https://openrouter.ai/keys)."
            )

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": self.site_url,
            "X-Title": self.app_name,
        }
        payload = {
            "model": model,
            "messages": [{"role": m.role, "content": m.content} for m in messages],
            "temperature": temperature,
        }

        async with httpx.AsyncClient(timeout=120.0) as client:
            response = await client.post(
                f"{self.base_url}/chat/completions",
                headers=headers,
                json=payload,
            )
            if response.status_code >= 400:
                detail = response.text[:800]
                raise RuntimeError(f"OpenRouter error {response.status_code}: {detail}")
            data = response.json()

        choices = data.get("choices") or []
        if not choices:
            raise RuntimeError(f"OpenRouter returned no choices: {data!r}")

        message = choices[0].get("message") or {}
        content = message.get("content") or ""
        usage = data.get("usage") or {}
        in_tok = int(usage.get("prompt_tokens") or 0)
        out_tok = int(usage.get("completion_tokens") or 0)
        # OpenRouter may include native cost (USD) on usage
        cost = usage.get("cost")
        if cost is None:
            cost = 0.0
        else:
            cost = float(cost)

        return ProviderResult(
            content=content,
            model=data.get("model") or model,
            input_tokens=in_tok,
            output_tokens=out_tok,
            cost_usd=round(cost, 6),
            cached=False,
        )
