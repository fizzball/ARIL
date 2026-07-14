"""In-memory session store with JSON file persistence."""

from __future__ import annotations

import json
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from app.core.schemas import ChatMessage, SessionDetail, SessionSummary, SessionUpsert

_LOCK = threading.Lock()
_DATA_DIR = Path(__file__).resolve().parents[2] / "data"
_STORE_PATH = _DATA_DIR / "sessions.json"
_SESSIONS: dict[str, dict] = {}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ensure_loaded() -> None:
    global _SESSIONS
    if _SESSIONS:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    if _STORE_PATH.exists():
        try:
            raw = json.loads(_STORE_PATH.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                _SESSIONS = raw
        except (json.JSONDecodeError, OSError):
            _SESSIONS = {}


def _persist() -> None:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    _STORE_PATH.write_text(json.dumps(_SESSIONS, indent=2), encoding="utf-8")


def list_sessions() -> list[SessionSummary]:
    with _LOCK:
        _ensure_loaded()
        rows = []
        for sid, row in _SESSIONS.items():
            msgs = row.get("messages") or []
            rows.append(
                SessionSummary(
                    id=sid,
                    title=row.get("title") or "Untitled",
                    updated_at=row.get("updated_at") or _now(),
                    message_count=len(msgs),
                )
            )
        rows.sort(key=lambda s: s.updated_at, reverse=True)
        return rows


def get_session(session_id: str) -> SessionDetail | None:
    with _LOCK:
        _ensure_loaded()
        row = _SESSIONS.get(session_id)
        if not row:
            return None
        messages = [ChatMessage(**m) for m in (row.get("messages") or [])]
        return SessionDetail(
            id=session_id,
            title=row.get("title") or "Untitled",
            updated_at=row.get("updated_at") or _now(),
            messages=messages,
        )


def upsert_session(payload: SessionUpsert) -> SessionDetail:
    with _LOCK:
        _ensure_loaded()
        sid = payload.id or str(uuid.uuid4())
        row = {
            "title": payload.title,
            "updated_at": _now(),
            "messages": [m.model_dump() for m in payload.messages],
        }
        _SESSIONS[sid] = row
        _persist()
        return SessionDetail(
            id=sid,
            title=row["title"],
            updated_at=row["updated_at"],
            messages=payload.messages,
        )


def append_turn(
    session_id: str,
    *,
    title: str | None,
    user: ChatMessage | None,
    assistant: ChatMessage | None,
) -> SessionDetail:
    with _LOCK:
        _ensure_loaded()
        row = _SESSIONS.get(session_id) or {
            "title": title or "New session",
            "updated_at": _now(),
            "messages": [],
        }
        if title:
            row["title"] = title
        msgs = list(row.get("messages") or [])
        if user:
            msgs.append(user.model_dump())
        if assistant:
            msgs.append(assistant.model_dump())
        row["messages"] = msgs
        row["updated_at"] = _now()
        _SESSIONS[session_id] = row
        _persist()
        return SessionDetail(
            id=session_id,
            title=row["title"],
            updated_at=row["updated_at"],
            messages=[ChatMessage(**m) for m in msgs],
        )


def delete_session(session_id: str) -> bool:
    with _LOCK:
        _ensure_loaded()
        if session_id not in _SESSIONS:
            return False
        del _SESSIONS[session_id]
        _persist()
        return True
