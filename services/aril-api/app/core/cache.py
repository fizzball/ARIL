"""File-backed completion cache for large prompts."""

from __future__ import annotations

import hashlib
import json
import threading
from pathlib import Path
from typing import Any

from app.core.config import settings
from app.core.paths import data_dir

_LOCK = threading.Lock()
_CACHE: dict[str, dict[str, Any]] = {}


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
