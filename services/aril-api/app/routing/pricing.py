"""Fetch and cache OpenRouter model pricing (USD per 1K tokens) + catalog."""

from __future__ import annotations

import threading
import time
from typing import Any

import httpx

from app.core.config import settings

# Fallback when OpenRouter is unreachable — roughly mid-range USD / 1K tokens.
FALLBACK_COST_PER_1K: dict[str, tuple[float, float]] = {
    "openai/gpt-4.1": (0.002, 0.008),
    "openai/gpt-4.1-mini": (0.0004, 0.0016),
    "anthropic/claude-sonnet-4": (0.003, 0.015),
    "anthropic/claude-opus-4": (0.015, 0.075),
    "google/gemini-2.5-flash": (0.0003, 0.0025),
    "google/gemini-2.5-flash-image": (0.0003, 0.0025),
    "meta-llama/llama-3.3-70b-instruct": (0.0001, 0.0003),
}

# OpenRouter Exa/Parallel/Perplexity plugin default when a model has no native fee.
DEFAULT_WEB_SEARCH_PER_REQUEST = 0.005

_LOCK = threading.Lock()
_CACHE: dict[str, dict[str, float]] = {}
_CATALOG: list[dict[str, Any]] = []
_CACHE_AT: float = 0.0
_TTL_SECONDS = 3600.0


def _per_token_to_per_1k(value: Any) -> float:
    try:
        return max(0.0, float(value) * 1000.0)
    except (TypeError, ValueError):
        return 0.0


def _refresh_cache() -> None:
    """Pull the public OpenRouter models catalog (pricing does not require a key)."""
    global _CACHE, _CACHE_AT, _CATALOG
    url = settings.openrouter_base_url.rstrip("/") + "/models"
    headers = {
        "Accept": "application/json",
        "HTTP-Referer": settings.openrouter_site_url,
        "X-Title": settings.openrouter_app_name,
    }
    if settings.openrouter_api_key.strip():
        headers["Authorization"] = f"Bearer {settings.openrouter_api_key.strip()}"
    try:
        with httpx.Client(timeout=20.0) as client:
            resp = client.get(url, headers=headers)
            resp.raise_for_status()
            payload = resp.json()
    except Exception:
        return

    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return

    next_cache: dict[str, dict[str, float]] = {}
    next_catalog: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        mid = row.get("id")
        pricing = row.get("pricing") or {}
        if not isinstance(mid, str) or not isinstance(pricing, dict):
            continue
        prompt_1k = _per_token_to_per_1k(pricing.get("prompt"))
        completion_1k = _per_token_to_per_1k(pricing.get("completion"))
        try:
            web_search = max(0.0, float(pricing.get("web_search") or 0.0))
        except (TypeError, ValueError):
            web_search = 0.0
        rates = {
            "prompt_per_1k": prompt_1k,
            "completion_per_1k": completion_1k,
            "web_search_per_request": web_search,
        }
        next_cache[mid] = rates
        name = row.get("name") if isinstance(row.get("name"), str) else mid
        next_catalog.append(
            {
                "id": mid,
                "name": name,
                "prompt_per_1k": prompt_1k,
                "completion_per_1k": completion_1k,
                "web_search_per_request": web_search
                if web_search > 0
                else DEFAULT_WEB_SEARCH_PER_REQUEST,
                "context_length": row.get("context_length"),
            }
        )
    if next_cache:
        next_catalog.sort(key=lambda r: str(r["id"]).lower())
        _CACHE = next_cache
        _CATALOG = next_catalog
        _CACHE_AT = time.time()


def ensure_pricing_cache(*, force: bool = False) -> None:
    with _LOCK:
        stale = (time.time() - _CACHE_AT) > _TTL_SECONDS
        if force or not _CACHE or stale:
            _refresh_cache()


def lookup_pricing(model_id: str) -> dict[str, float]:
    """Return prompt/completion USD per 1K tokens for a model id."""
    ensure_pricing_cache()
    with _LOCK:
        hit = _CACHE.get(model_id)
        if hit:
            return dict(hit)
        # Prefix match — catalog ids sometimes lag OpenRouter suffixes.
        for key, row in _CACHE.items():
            if key.startswith(model_id) or model_id.startswith(key):
                return dict(row)

    fallback = FALLBACK_COST_PER_1K.get(model_id)
    if fallback:
        return {
            "prompt_per_1k": fallback[0],
            "completion_per_1k": fallback[1],
            "web_search_per_request": DEFAULT_WEB_SEARCH_PER_REQUEST,
        }
    return {
        "prompt_per_1k": 0.01,
        "completion_per_1k": 0.03,
        "web_search_per_request": DEFAULT_WEB_SEARCH_PER_REQUEST,
    }


def _in_cache(model_id: str) -> bool:
    with _LOCK:
        if model_id in _CACHE:
            return True
        return any(k.startswith(model_id) or model_id.startswith(k) for k in _CACHE)


def pricing_for_models(model_ids: list[str], *, force_refresh: bool = False) -> list[dict[str, Any]]:
    ensure_pricing_cache(force=force_refresh)
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for mid in model_ids:
        if not mid or mid in seen:
            continue
        seen.add(mid)
        rates = lookup_pricing(mid)
        web_fee = float(rates.get("web_search_per_request") or 0.0)
        if web_fee <= 0:
            web_fee = DEFAULT_WEB_SEARCH_PER_REQUEST
        out.append(
            {
                "id": mid,
                "prompt_per_1k": rates["prompt_per_1k"],
                "completion_per_1k": rates["completion_per_1k"],
                "web_search_per_request": web_fee,
                "source": "openrouter" if _in_cache(mid) else "fallback",
            }
        )
    return out


def list_catalog(*, query: str | None = None, force_refresh: bool = False) -> list[dict[str, Any]]:
    """Return OpenRouter models (optionally filtered), including pricing."""
    ensure_pricing_cache(force=force_refresh)
    with _LOCK:
        rows = list(_CATALOG)
    if not rows:
        # Offline fallback — curated catalog only.
        rows = [
            {
                "id": mid,
                "name": mid,
                "prompt_per_1k": rates[0],
                "completion_per_1k": rates[1],
                "web_search_per_request": DEFAULT_WEB_SEARCH_PER_REQUEST,
                "context_length": None,
            }
            for mid, rates in FALLBACK_COST_PER_1K.items()
        ]
    q = (query or "").strip().lower()
    if q:
        rows = [
            r
            for r in rows
            if q in str(r.get("id", "")).lower() or q in str(r.get("name", "")).lower()
        ]
    return rows


def estimate_cost_usd(
    model_id: str,
    *,
    input_tokens: int,
    output_tokens: int,
    web_search: bool = False,
) -> float:
    rates = lookup_pricing(model_id)
    cost = (input_tokens / 1000.0) * rates["prompt_per_1k"] + (
        output_tokens / 1000.0
    ) * rates["completion_per_1k"]
    if web_search:
        cost += float(rates.get("web_search_per_request") or 0.005)
    return round(cost, 6)


def resolve_cost_usd(
    model_id: str,
    *,
    reported_cost: float | None,
    input_tokens: int,
    output_tokens: int,
    web_search: bool = False,
) -> float:
    """Prefer provider-reported USD cost; otherwise price from token counts."""
    if reported_cost and reported_cost > 0:
        return round(float(reported_cost), 6)
    if input_tokens <= 0 and output_tokens <= 0:
        return round(float(reported_cost or 0.0), 6)
    return estimate_cost_usd(
        model_id,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        web_search=web_search,
    )
