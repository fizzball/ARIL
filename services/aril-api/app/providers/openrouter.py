"""OpenRouter provider — multi-model routing, multimodal, web plugin, SSE."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator

import httpx

from app.core.config import settings
from app.providers.base import LLMProvider, ProviderMessage, ProviderResult, StreamChunk


class OpenRouterProvider(LLMProvider):
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

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": self.site_url,
            "X-Title": self.app_name,
        }

    def _require_key(self) -> None:
        if not self.api_key:
            raise RuntimeError(
                "OPENROUTER_API_KEY is not set. Add it to services/aril-api/.env "
                "(https://openrouter.ai/keys)."
            )

    def _serialize_messages(self, messages: list[ProviderMessage]) -> list[dict]:
        out: list[dict] = []
        for m in messages:
            if m.parts:
                out.append({"role": m.role, "content": m.parts})
            else:
                out.append({"role": m.role, "content": m.content})
        return out

    def _build_payload(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
        stream: bool,
        web_search: bool,
    ) -> dict:
        payload: dict = {
            "model": model,
            "messages": self._serialize_messages(messages),
            "temperature": temperature,
        }
        if stream:
            payload["stream"] = True
            payload["stream_options"] = {"include_usage": True}
        if web_search:
            # OpenRouter web plugin — live search grounded answers
            payload["plugins"] = [{"id": "web"}]
        return payload

    async def complete(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
        web_search: bool = False,
    ) -> ProviderResult:
        self._require_key()
        payload = self._build_payload(
            messages, model=model, temperature=temperature, stream=False, web_search=web_search
        )

        async with httpx.AsyncClient(timeout=180.0) as client:
            response = await client.post(
                f"{self.base_url}/chat/completions",
                headers=self._headers(),
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
        cost = float(usage.get("cost") or 0.0)

        return ProviderResult(
            content=content,
            model=data.get("model") or model,
            input_tokens=in_tok,
            output_tokens=out_tok,
            cost_usd=round(cost, 6),
            cached=False,
        )

    async def stream(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
        web_search: bool = False,
    ) -> AsyncIterator[StreamChunk]:
        self._require_key()
        payload = self._build_payload(
            messages, model=model, temperature=temperature, stream=True, web_search=web_search
        )

        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream(
                "POST",
                f"{self.base_url}/chat/completions",
                headers=self._headers(),
                json=payload,
            ) as response:
                if response.status_code >= 400:
                    detail = (await response.aread()).decode("utf-8", errors="replace")[:800]
                    raise RuntimeError(f"OpenRouter error {response.status_code}: {detail}")

                async for line in response.aiter_lines():
                    if not line or not line.startswith("data:"):
                        continue
                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        break
                    try:
                        data = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    chunk = StreamChunk(model=data.get("model") or model)
                    choices = data.get("choices") or []
                    if choices:
                        delta = choices[0].get("delta") or {}
                        chunk.content = delta.get("content") or ""
                        chunk.finish_reason = choices[0].get("finish_reason")
                    usage = data.get("usage") or {}
                    if usage:
                        chunk.input_tokens = int(usage.get("prompt_tokens") or 0)
                        chunk.output_tokens = int(usage.get("completion_tokens") or 0)
                        chunk.cost_usd = float(usage.get("cost") or 0.0)
                    yield chunk

        yield StreamChunk(done=True)
