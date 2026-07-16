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
_WEEKLY_RANKINGS: list[dict[str, Any]] = []
_WEEKLY_RANKINGS_AT: float = 0.0
_WEEKLY_RANKINGS_TTL_SECONDS = 900.0  # 15 minutes


def _openrouter_headers() -> dict[str, str]:
    headers = {
        "Accept": "application/json",
        "HTTP-Referer": settings.openrouter_site_url,
        "X-Title": settings.openrouter_app_name,
    }
    if settings.openrouter_api_key.strip():
        headers["Authorization"] = f"Bearer {settings.openrouter_api_key.strip()}"
    return headers


def _per_token_to_per_1k(value: Any) -> float:
    try:
        return max(0.0, float(value) * 1000.0)
    except (TypeError, ValueError):
        return 0.0


def _normalize_modality_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            continue
        token = item.strip().lower()
        if not token or token in seen:
            continue
        seen.add(token)
        out.append(token)
    return out


def modalities_from_catalog_row(row: dict[str, Any]) -> tuple[list[str], list[str]]:
    """Extract input/output modalities from an OpenRouter /models row."""
    arch = row.get("architecture")
    if isinstance(arch, dict):
        inputs = _normalize_modality_list(arch.get("input_modalities"))
        outputs = _normalize_modality_list(arch.get("output_modalities"))
        if inputs or outputs:
            return inputs, outputs
        # Older catalog shape: "text+image->text"
        modality = arch.get("modality")
        if isinstance(modality, str) and "->" in modality:
            left, _, right = modality.partition("->")
            inputs = [p.strip().lower() for p in left.split("+") if p.strip()]
            outputs = [p.strip().lower() for p in right.split("+") if p.strip()]
            return inputs, outputs
    return (
        _normalize_modality_list(row.get("input_modalities")),
        _normalize_modality_list(row.get("output_modalities")),
    )


def _refresh_cache() -> None:
    """Pull the public OpenRouter models catalog (pricing does not require a key)."""
    global _CACHE, _CACHE_AT, _CATALOG
    url = settings.openrouter_base_url.rstrip("/") + "/models"
    headers = _openrouter_headers()
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
        input_mods, output_mods = modalities_from_catalog_row(row)
        context_length = row.get("context_length")
        if not isinstance(context_length, int):
            context_length = None
        next_catalog.append(
            {
                "id": mid,
                "name": name,
                "prompt_per_1k": prompt_1k,
                "completion_per_1k": completion_1k,
                "web_search_per_request": web_search
                if web_search > 0
                else DEFAULT_WEB_SEARCH_PER_REQUEST,
                "context_length": context_length,
                "input_modalities": input_mods,
                "output_modalities": output_mods,
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
                "input_modalities": ["text", "image"]
                if "image" in mid or "vision" in mid or "-vl" in mid
                else ["text"],
                "output_modalities": ["image", "text"] if "image" in mid else ["text"],
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


def _refresh_weekly_rankings(*, limit: int = 25) -> None:
    """Pull OpenRouter `/models?sort=top-weekly` (tokens processed last week)."""
    global _WEEKLY_RANKINGS, _WEEKLY_RANKINGS_AT
    url = settings.openrouter_base_url.rstrip("/") + "/models"
    try:
        with httpx.Client(timeout=20.0) as client:
            resp = client.get(
                url,
                headers=_openrouter_headers(),
                params={"sort": "top-weekly"},
            )
            resp.raise_for_status()
            payload = resp.json()
    except Exception:
        return

    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return

    out: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        mid = row.get("id")
        if not isinstance(mid, str) or not mid.strip():
            continue
        pricing = row.get("pricing") or {}
        if not isinstance(pricing, dict):
            pricing = {}
        name = row.get("name") if isinstance(row.get("name"), str) else mid
        out.append(
            {
                "rank": len(out) + 1,
                "id": mid.strip(),
                "name": name,
                "prompt_per_1k": _per_token_to_per_1k(pricing.get("prompt")),
                "completion_per_1k": _per_token_to_per_1k(pricing.get("completion")),
            }
        )
        if len(out) >= max(1, limit):
            break
    if out:
        with _LOCK:
            _WEEKLY_RANKINGS = out
            _WEEKLY_RANKINGS_AT = time.time()


def list_weekly_rankings(
    *, limit: int = 25, force_refresh: bool = False
) -> list[dict[str, Any]]:
    """Top models by OpenRouter weekly token volume (`sort=top-weekly`)."""
    cap = min(100, max(1, int(limit)))
    with _LOCK:
        stale = (time.time() - _WEEKLY_RANKINGS_AT) > _WEEKLY_RANKINGS_TTL_SECONDS
        have = list(_WEEKLY_RANKINGS)
    if force_refresh or not have or stale:
        _refresh_weekly_rankings(limit=cap)
        with _LOCK:
            have = list(_WEEKLY_RANKINGS)
    return have[:cap]


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
