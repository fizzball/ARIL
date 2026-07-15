"""OpenRouter API key helpers — mask for UI and persist to .env."""

from __future__ import annotations

import re
from pathlib import Path

from app.core.config import settings
from app.core.paths import data_dir

_MASK_LEN = 20


def _env_path() -> Path:
    """Prefer Application Support / ARIL_DATA_DIR; fall back to package .env for dev."""
    if (settings.aril_data_dir or "").strip():
        return data_dir() / ".env"
    return Path(__file__).resolve().parents[2] / ".env"


def mask_api_key(key: str) -> str:
    """Show the key with the last 10 characters replaced by bullets."""
    value = (key or "").strip()
    if not value:
        return ""
    if len(value) <= _MASK_LEN:
        return "•" * len(value)
    return value[:-_MASK_LEN] + ("•" * _MASK_LEN)


def is_configured() -> bool:
    return bool(settings.openrouter_api_key.strip())


def status() -> dict:
    key = settings.openrouter_api_key.strip()
    return {
        "configured": bool(key),
        "masked_key": mask_api_key(key) if key else "",
        "required": True,
    }


def _upsert_env_key(key: str) -> None:
    path = _env_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    line = f"OPENROUTER_API_KEY={key}"
    if path.exists():
        text = path.read_text(encoding="utf-8")
        if re.search(r"(?m)^OPENROUTER_API_KEY=.*$", text):
            text = re.sub(r"(?m)^OPENROUTER_API_KEY=.*$", line, text)
        else:
            text = text.rstrip() + "\n" + line + "\n"
        path.write_text(text, encoding="utf-8")
    else:
        path.write_text(
            "# ARIL API — local secrets (do not commit)\n"
            f"{line}\n",
            encoding="utf-8",
        )


def set_api_key(key: str) -> dict:
    cleaned = (key or "").strip()
    if not cleaned:
        raise ValueError("API key cannot be empty")
    settings.openrouter_api_key = cleaned
    _upsert_env_key(cleaned)
    return status()


def clear_api_key() -> dict:
    settings.openrouter_api_key = ""
    _upsert_env_key("")
    return status()
