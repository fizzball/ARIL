"""Resolve writable ARIL data directories for solo / packaged runs."""

from __future__ import annotations

from pathlib import Path

from app.core.config import settings


def data_dir() -> Path:
    """SQLite, sessions, cache, and local .env live here.

    When ``ARIL_DATA_DIR`` is set (macOS app Solo mode), use that path so a
    read-only app bundle never needs to write beside itself.
    """
    raw = (settings.aril_data_dir or "").strip()
    if raw:
        return Path(raw).expanduser().resolve()
    return Path(__file__).resolve().parents[2] / "data"
