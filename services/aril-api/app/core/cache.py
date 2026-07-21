"""File-backed completion cache for large prompts."""

from __future__ import annotations

import hashlib
import json
import threading
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from app.core.config import settings
from app.core.paths import data_dir

_LOCK = threading.Lock()
_CACHE: dict[str, dict[str, Any]] = {}

# Minimum similarity to offer a prior cached prompt as a hit alternative.
_SUGGEST_RATIO = 0.82


def _cache_path() -> Path:
    return data_dir() / "prompt_cache.json"


def _ensure_loaded() -> None:
    global _CACHE
    if _CACHE:
        return
    data_dir().mkdir(parents=True, exist_ok=True)
    path = _cache_path()
    if path.exists():
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                _CACHE = raw
        except (json.JSONDecodeError, OSError):
            _CACHE = {}


def _persist() -> None:
    data_dir().mkdir(parents=True, exist_ok=True)
    # Cap store size
    if len(_CACHE) > 500:
        # drop oldest by inserted_at
        items = sorted(_CACHE.items(), key=lambda kv: kv[1].get("inserted_at", ""))
        for key, _ in items[: len(_CACHE) - 400]:
            _CACHE.pop(key, None)
    _cache_path().write_text(json.dumps(_CACHE), encoding="utf-8")


def make_key(
    *,
    messages: list[dict[str, str]],
    model: str,
    temperature: float,
) -> str:
    payload = json.dumps(
        {"messages": messages, "model": model, "temperature": round(temperature, 2)},
        sort_keys=True,
        ensure_ascii=False,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def eligible(input_tokens: int) -> bool:
    return input_tokens > settings.aril_cache_token_threshold


def peek(key: str) -> dict[str, Any] | None:
    with _LOCK:
        _ensure_loaded()
        hit = _CACHE.get(key)
        return dict(hit) if hit else None


def put(key: str, value: dict[str, Any]) -> None:
    from datetime import datetime, timezone

    with _LOCK:
        _ensure_loaded()
        row = dict(value)
        row["inserted_at"] = datetime.now(timezone.utc).isoformat()
        _CACHE[key] = row
        _persist()


def savings_pct() -> float:
    return 55.0


def _normalize_prompt(text: str) -> str:
    return " ".join((text or "").split()).strip().lower()


def suggest_hit(
    *,
    prompt: str,
    model: str,
    temperature: float,
) -> dict[str, Any] | None:
    """Return a prior cached user prompt that would hit for this model/temp.

    Used when the draft is close to a previously cached prompt so the UI can
    offer that text (Edit / Submit) for a cache hit.
    """
    needle = _normalize_prompt(prompt)
    if len(needle) < 48:
        return None
    temp = round(temperature, 2)
    best: tuple[float, dict[str, Any]] | None = None
    with _LOCK:
        _ensure_loaded()
        rows = list(_CACHE.values())
    for row in rows:
        stored = (row.get("user_prompt") or "").strip()
        if not stored:
            continue
        if (row.get("model") or "") != model:
            continue
        try:
            row_temp = round(float(row.get("temperature", temp)), 2)
        except (TypeError, ValueError):
            row_temp = temp
        if row_temp != temp:
            continue
        hay = _normalize_prompt(stored)
        if not hay or hay == needle:
            # Exact normalized match is already a would_hit for single-turn keys.
            continue
        # Prefer cases where the user is typing toward a known long prompt.
        if hay.startswith(needle) or needle.startswith(hay):
            ratio = min(len(needle), len(hay)) / max(len(needle), len(hay))
            ratio = max(ratio, 0.9)
        else:
            ratio = SequenceMatcher(None, needle, hay).ratio()
        if ratio < _SUGGEST_RATIO:
            continue
        if best is None or ratio > best[0]:
            best = (ratio, {"prompt": stored, "ratio": ratio, "model": model})
    if best is None:
        return None
    return best[1]
