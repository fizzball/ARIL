"""Preference learning from compare winners and user classification overrides."""

from __future__ import annotations

import json
import re
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_LOCK = threading.Lock()
_DATA_DIR = Path(__file__).resolve().parents[2] / "data"
_PATH = _DATA_DIR / "preferences.json"
# category -> model -> wins
_WINS: dict[str, dict[str, int]] = {}
# fingerprint -> model -> wins (finer grain)
_FP: dict[str, dict[str, int]] = {}
# User classifications / accuracy overrides for like queries
_CLASSIFICATIONS: list[dict[str, Any]] = []
_LOADED = False


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ensure() -> None:
    global _WINS, _FP, _CLASSIFICATIONS, _LOADED
    if _LOADED:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    if _PATH.exists():
        try:
            raw = json.loads(_PATH.read_text(encoding="utf-8"))
            _WINS = raw.get("category_wins") or {}
            _FP = raw.get("fingerprint_wins") or {}
            _CLASSIFICATIONS = list(raw.get("classifications") or [])
        except (json.JSONDecodeError, OSError):
            _WINS, _FP, _CLASSIFICATIONS = {}, {}, []
    _LOADED = True


def _persist() -> None:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    _PATH.write_text(
        json.dumps(
            {
                "category_wins": _WINS,
                "fingerprint_wins": _FP,
                "classifications": _CLASSIFICATIONS,
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def fingerprint(prompt: str) -> str:
    tokens = re.findall(r"[a-z0-9]{3,}", prompt.lower())
    uniq = sorted(set(tokens))[:24]
    return "|".join(uniq) if uniq else "general"


def record_preference(
    *,
    prompt: str,
    category: str,
    model: str,
    accuracy: float | None = None,
    category_overridden: bool = False,
) -> dict:
    with _LOCK:
        _ensure()
        cat = _WINS.setdefault(category, {})
        cat[model] = int(cat.get(model, 0)) + 1
        fp = fingerprint(prompt)
        bucket = _FP.setdefault(fp, {})
        bucket[model] = int(bucket.get(model, 0)) + 1

        # Upsert classification by fingerprint (latest user judgment wins)
        existing = next((c for c in _CLASSIFICATIONS if c.get("fingerprint") == fp), None)
        snippet = (prompt or "").strip().replace("\n", " ")[:120]
        if existing:
            existing["category"] = category
            existing["model"] = model
            existing["prompt_snippet"] = snippet
            existing["prompt"] = prompt
            existing["category_overridden"] = bool(category_overridden or existing.get("category_overridden"))
            if accuracy is not None:
                existing["accuracy"] = float(accuracy)
            existing["updated_at"] = _now()
            classification = existing
        else:
            classification = {
                "id": str(uuid.uuid4()),
                "prompt": prompt,
                "prompt_snippet": snippet,
                "fingerprint": fp,
                "category": category,
                "model": model,
                "accuracy": float(accuracy) if accuracy is not None else None,
                "category_overridden": bool(category_overridden),
                "created_at": _now(),
                "updated_at": _now(),
            }
            _CLASSIFICATIONS.insert(0, classification)

        _persist()
        return {
            "category": category,
            "fingerprint": fp,
            "model": model,
            "category_wins": cat[model],
            "fingerprint_wins": bucket[model],
            "classification_id": classification["id"],
            "accuracy": classification.get("accuracy"),
            "category_overridden": classification.get("category_overridden", False),
        }


def lookup_classification(prompt: str) -> dict | None:
    with _LOCK:
        _ensure()
        fp = fingerprint(prompt)
        return next((c for c in _CLASSIFICATIONS if c.get("fingerprint") == fp), None)


def confidence_boost(prompt: str, category: str, model: str) -> float:
    """0..0.40 boost applied to route score (wins + accuracy)."""
    with _LOCK:
        _ensure()
        cat_wins = (_WINS.get(category) or {}).get(model, 0)
        fp = fingerprint(prompt)
        fp_wins = (_FP.get(fp) or {}).get(model, 0)
        boost = min(0.2, cat_wins * 0.04) + min(0.15, fp_wins * 0.05)
        entry = next((c for c in _CLASSIFICATIONS if c.get("fingerprint") == fp), None)
        if entry and entry.get("model") == model and entry.get("accuracy") is not None:
            boost += 0.05 * float(entry["accuracy"])
        return round(min(0.4, boost), 3)


def list_classifications() -> list[dict]:
    with _LOCK:
        _ensure()
        return list(_CLASSIFICATIONS)


def update_classification(
    classification_id: str,
    *,
    category: str | None = None,
    accuracy: float | None = None,
    model: str | None = None,
    remove_accuracy: bool = False,
) -> dict | None:
    with _LOCK:
        _ensure()
        for entry in _CLASSIFICATIONS:
            if entry.get("id") != classification_id:
                continue
            if category is not None and category != entry.get("category"):
                entry["category"] = category
                entry["category_overridden"] = True
                # Keep model wins in sync for the new category
                mid = model or entry.get("model")
                if mid:
                    cat = _WINS.setdefault(category, {})
                    cat[mid] = int(cat.get(mid, 0)) + 1
            if model is not None:
                entry["model"] = model
            if remove_accuracy:
                entry["accuracy"] = None
            elif accuracy is not None:
                entry["accuracy"] = float(accuracy)
            entry["updated_at"] = _now()
            _persist()
            return dict(entry)
        return None


def delete_classification(classification_id: str) -> bool:
    with _LOCK:
        _ensure()
        before = len(_CLASSIFICATIONS)
        _CLASSIFICATIONS[:] = [c for c in _CLASSIFICATIONS if c.get("id") != classification_id]
        if len(_CLASSIFICATIONS) == before:
            return False
        _persist()
        return True


def snapshot() -> dict:
    with _LOCK:
        _ensure()
        return {
            "category_wins": _WINS,
            "fingerprint_wins": _FP,
            "classifications": list(_CLASSIFICATIONS),
        }
