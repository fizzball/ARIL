"""OpenRouter provider — multi-model routing, multimodal, web plugin, SSE."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator

import httpx

from app.core.config import settings
from app.providers.base import LLMProvider, ProviderMessage, ProviderResult, StreamChunk


def _extract_message_content(message: dict) -> str:
    """Flatten text + OpenRouter image payloads into markdown-friendly content."""
    content = message.get("content") or ""
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text" and item.get("text"):
                parts.append(str(item["text"]))
            elif item.get("type") == "image_url":
                url = ((item.get("image_url") or {}) if isinstance(item.get("image_url"), dict) else {}).get(
                    "url"
                ) or item.get("url")
                if url:
                    parts.append(f"![Generated image]({url})")
        content = "\n\n".join(parts)

    images = message.get("images") or []
    image_mds: list[str] = []
    for img in images:
        if not isinstance(img, dict):
            continue
        image_url = img.get("image_url") if isinstance(img.get("image_url"), dict) else {}
        url = (image_url or {}).get("url") or img.get("url")
        if url:
            image_mds.append(f"![Generated image]({url})")
    if image_mds:
        extra = "\n\n".join(image_mds)
        content = f"{content}\n\n{extra}".strip() if content else extra
    return content if isinstance(content, str) else str(content)


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
            # Some OpenRouter/CDN responses mislabel Content-Encoding; identity
            # avoids zlib "incorrect header check" failures in httpx.
            "Accept-Encoding": "identity",
        }

    def _client(self, *, timeout: float | httpx.Timeout | None = 180.0) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            timeout=timeout,
            headers={"Accept-Encoding": "identity"},
        )

    def _require_key(self) -> None:
        if not self.api_key:
            raise RuntimeError(
                "OPENROUTER_API_KEY is not set. Add it to services/aril-api/.env "
                "(https://openrouter.ai/keys)."
            )

    def _serialize_messages(self, messages: list[ProviderMessage]) -> list[dict]:
        out: list[dict] = []
        for m in messages:
            if m.role == "tool":
                entry: dict = {
                    "role": "tool",
                    "content": m.content or "",
                }
                if m.tool_call_id:
                    entry["tool_call_id"] = m.tool_call_id
                out.append(entry)
                continue
            if m.parts:
                entry = {"role": m.role, "content": m.parts}
            else:
                entry = {"role": m.role, "content": m.content}
            if m.tool_calls:
                entry["tool_calls"] = m.tool_calls
                # OpenAI allows null content when tool_calls are present
                if not m.content and not m.parts:
                    entry["content"] = None
            out.append(entry)
        return out

    def _build_payload(
        self,
        messages: list[ProviderMessage],
        *,
        model: str,
        temperature: float,
        stream: bool,
        web_search: bool,
        generate_image: bool = False,
        tools: list[dict] | None = None,
        tool_choice: str | None = None,
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
        if generate_image:
            # Required for image-capable chat models (Gemini Flash Image, etc.)
            model_l = (model or "").lower()
            if any(tok in model_l for tok in ("flux", "sourceful", "seedream", "dall-e", "dalle")):
                payload["modalities"] = ["image"]
            else:
                payload["modalities"] = ["image", "text"]
        if tools:
            payload["tools"] = tools
            if tool_choice:
                payload["tool_choice"] = tool_choice
        return payload

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
        self._require_key()
        payload = self._build_payload(
            messages,
            model=model,
            temperature=temperature,
            stream=False,
            web_search=web_search,
            generate_image=generate_image,
            tools=tools,
            tool_choice=tool_choice,
        )

        async with self._client(timeout=180.0) as client:
            try:
                response = await client.post(
                    f"{self.base_url}/chat/completions",
                    headers=self._headers(),
                    json=payload,
                )
            except Exception as exc:  # noqa: BLE001
                raise RuntimeError(f"OpenRouter request failed: {exc}") from exc
            if response.status_code >= 400:
                detail = response.text[:800]
                raise RuntimeError(f"OpenRouter error {response.status_code}: {detail}")
            try:
                data = response.json()
            except Exception as exc:  # noqa: BLE001
                raise RuntimeError(f"OpenRouter response decode failed: {exc}") from exc

        choices = data.get("choices") or []
        if not choices:
            raise RuntimeError(f"OpenRouter returned no choices: {data!r}")

        choice0 = choices[0] or {}
        message = choice0.get("message") or {}
        content = _extract_message_content(message)
        raw_calls = message.get("tool_calls")
        tool_calls = raw_calls if isinstance(raw_calls, list) and raw_calls else None
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
            tool_calls=tool_calls,
            finish_reason=choice0.get("finish_reason"),
        )

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
        # Image generation is more reliable as a single non-stream completion.
        # Tool rounds also use complete(); stream is for final text only.
        if generate_image or tools:
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
            return

        self._require_key()
        payload = self._build_payload(
            messages,
            model=model,
            temperature=temperature,
            stream=True,
            web_search=web_search,
            generate_image=False,
        )

        async with self._client(timeout=None) as client:
            try:
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
                            # Prefer incremental text; also fold any image payloads.
                            text = delta.get("content") or ""
                            if isinstance(text, list):
                                text = _extract_message_content({"content": text})
                            images = delta.get("images") or (choices[0].get("message") or {}).get("images")
                            if images:
                                folded = _extract_message_content({"content": text, "images": images})
                                chunk.content = folded
                            else:
                                chunk.content = text if isinstance(text, str) else str(text)
                            chunk.finish_reason = choices[0].get("finish_reason")
                        usage = data.get("usage") or {}
                        if usage:
                            chunk.input_tokens = int(usage.get("prompt_tokens") or 0)
                            chunk.output_tokens = int(usage.get("completion_tokens") or 0)
                            chunk.cost_usd = float(usage.get("cost") or 0.0)
                        yield chunk
            except RuntimeError:
                raise
            except Exception as exc:  # noqa: BLE001
                raise RuntimeError(f"OpenRouter stream failed: {exc}") from exc

        yield StreamChunk(done=True)
