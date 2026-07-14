"""Heuristic preference learning from user-selected compare winners."""

from __future__ import annotations

import json
import re
import threading
from collections import defaultdict
from pathlib import Path

_LOCK = threading.Lock()
_DATA_DIR = Path(__file__).resolve().parents[2] / "data"
_PATH = _DATA_DIR / "preferences.json"
# category -> model -> wins
_WINS: dict[str, dict[str, int]] = {}
# fingerprint -> model -> wins (finer grain)
_FP: dict[str, dict[str, int]] = {}


def _ensure() -> None:
    global _WINS, _FP
    if _WINS or _FP:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    if _PATH.exists():
        try:
            raw = json.loads(_PATH.read_text(encoding="utf-8"))
            _WINS = raw.get("category_wins") or {}
            _FP = raw.get("fingerprint_wins") or {}
        except (json.JSONDecodeError, OSError):
            _WINS, _FP = {}, {}


def _persist() -> None:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    _PATH.write_text(
        json.dumps({"category_wins": _WINS, "fingerprint_wins": _FP}, indent=2),
        encoding="utf-8",
    )


def fingerprint(prompt: str) -> str:
    tokens = re.findall(r"[a-z0-9]{3,}", prompt.lower())
    # Keep discriminative mid-frequency tokens
    uniq = sorted(set(tokens))[:24]
    return "|".join(uniq) if uniq else "general"


def record_preference(*, prompt: str, category: str, model: str) -> dict:
    with _LOCK:
        _ensure()
        cat = _WINS.setdefault(category, {})
        cat[model] = int(cat.get(model, 0)) + 1
        fp = fingerprint(prompt)
        bucket = _FP.setdefault(fp, {})
        bucket[model] = int(bucket.get(model, 0)) + 1
        _persist()
        return {
            "category": category,
            "fingerprint": fp,
            "model": model,
            "category_wins": cat[model],
            "fingerprint_wins": bucket[model],
        }


def confidence_boost(prompt: str, category: str, model: str) -> float:
    """0..0.35 boost applied to route score."""
    with _LOCK:
        _ensure()
        cat_wins = (_WINS.get(category) or {}).get(model, 0)
        fp_wins = (_FP.get(fingerprint(prompt)) or {}).get(model, 0)
        # Diminishing returns
        boost = min(0.2, cat_wins * 0.04) + min(0.15, fp_wins * 0.05)
        return round(boost, 3)


def snapshot() -> dict:
    with _LOCK:
        _ensure()
        return {"category_wins": _WINS, "fingerprint_wins": _FP}
