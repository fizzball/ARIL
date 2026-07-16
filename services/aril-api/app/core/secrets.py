"""OpenRouter API key helpers — mask for UI and persist to .env."""

from __future__ import annotations

import re
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

from app.core.config import settings
from app.core.paths import data_dir

_MASK_LEN = 20
_CHECK_TIMEOUT = 15.0


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
    if len(cleaned) < 20 or not cleaned.startswith("sk-or-"):
        raise ValueError("API key looks invalid — paste a key from openrouter.ai/keys (sk-or-…)")
    settings.openrouter_api_key = cleaned
    _upsert_env_key(cleaned)
    return status()


def clear_api_key() -> dict:
    settings.openrouter_api_key = ""
    _upsert_env_key("")
    return status()


async def check_connection() -> dict:
    """Validate the stored OpenRouter key against GET /key (auth required)."""
    key = settings.openrouter_api_key.strip()
    checked_at = datetime.now(timezone.utc).isoformat()
    base = {
        "configured": bool(key),
        "masked_key": mask_api_key(key) if key else "",
        "checked_at": checked_at,
        "credits_remaining": None,
        "credits_source": None,
    }
    if not key:
        return {
            **base,
            "ready": False,
            "latency_ms": None,
            "message": "No OpenRouter API key configured.",
        }

    base_url = settings.openrouter_base_url.rstrip("/")
    headers = {
        "Authorization": f"Bearer {key}",
        "Accept": "application/json",
        "HTTP-Referer": settings.openrouter_site_url,
        "X-Title": settings.openrouter_app_name,
    }
    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=_CHECK_TIMEOUT) as client:
            resp = await client.get(f"{base_url}/key", headers=headers)
            credits_resp = None
            if resp.status_code < 400:
                # Account balance needs GET /credits (management keys); try anyway —
                # standard keys often return 403, which we ignore.
                try:
                    credits_resp = await client.get(f"{base_url}/credits", headers=headers)
                except httpx.HTTPError:
                    credits_resp = None
        latency_ms = int((time.perf_counter() - started) * 1000)
    except httpx.TimeoutException:
        return {
            **base,
            "ready": False,
            "latency_ms": int((time.perf_counter() - started) * 1000),
            "message": "OpenRouter connection timed out.",
        }
    except httpx.HTTPError as exc:
        return {
            **base,
            "ready": False,
            "latency_ms": int((time.perf_counter() - started) * 1000),
            "message": f"OpenRouter unreachable: {exc}",
        }

    if resp.status_code == 401:
        return {
            **base,
            "ready": False,
            "latency_ms": latency_ms,
            "message": "OpenRouter rejected the API key (unauthorized).",
        }
    if resp.status_code >= 400:
        detail = (resp.text or "").strip()
        if len(detail) > 180:
            detail = detail[:177] + "…"
        return {
            **base,
            "ready": False,
            "latency_ms": latency_ms,
            "message": f"OpenRouter error {resp.status_code}"
            + (f": {detail}" if detail else "."),
        }

    label = ""
    credits_remaining: float | None = None
    credits_source: str | None = None
    try:
        payload = resp.json()
        data = payload.get("data") if isinstance(payload, dict) else None
        if isinstance(data, dict):
            if isinstance(data.get("label"), str):
                label = data["label"].strip()
            # Per-key spending cap remaining (USD); null when the key is uncapped.
            raw_limit = data.get("limit_remaining")
            if isinstance(raw_limit, (int, float)):
                credits_remaining = float(raw_limit)
                credits_source = "key_limit"
    except Exception:  # noqa: BLE001
        pass

    if credits_resp is not None and credits_resp.status_code < 400:
        try:
            credits_payload = credits_resp.json()
            credits_data = (
                credits_payload.get("data") if isinstance(credits_payload, dict) else None
            )
            if isinstance(credits_data, dict):
                total = credits_data.get("total_credits")
                used = credits_data.get("total_usage")
                if isinstance(total, (int, float)) and isinstance(used, (int, float)):
                    credits_remaining = max(0.0, float(total) - float(used))
                    credits_source = "account"
        except Exception:  # noqa: BLE001
            pass

    suffix_parts: list[str] = []
    if label:
        suffix_parts.append(label)
    if credits_remaining is not None:
        suffix_parts.append(f"credits ${credits_remaining:,.2f}")
    suffix = f" ({', '.join(suffix_parts)})" if suffix_parts else ""
    return {
        **base,
        "ready": True,
        "latency_ms": latency_ms,
        "credits_remaining": credits_remaining,
        "credits_source": credits_source,
        "message": f"Connected to OpenRouter{suffix} · {latency_ms} ms",
    }
