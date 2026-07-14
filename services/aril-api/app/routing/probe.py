"""Lightweight latency probe — single completion token per model."""

from __future__ import annotations

import asyncio
import time

from app.core.schemas import ProbeRequest, ProbeResponse, ProbeResult
from app.providers.base import ProviderMessage, get_chat_provider


async def probe_models(req: ProbeRequest) -> ProbeResponse:
    provider = get_chat_provider()

    async def one(model: str) -> ProbeResult:
        started = time.perf_counter()
        try:
            # Tiny completion to measure round-trip latency
            await provider.complete(
                [ProviderMessage(role="user", content="Reply with exactly: ok")],
                model=model,
                temperature=0,
            )
            ms = int((time.perf_counter() - started) * 1000)
            return ProbeResult(model=model, latency_ms=ms)
        except Exception as exc:  # noqa: BLE001
            ms = int((time.perf_counter() - started) * 1000)
            return ProbeResult(model=model, latency_ms=ms, error=str(exc))

    results = await asyncio.gather(*[one(m) for m in req.models])
    return ProbeResponse(results=list(results))
