"""In-memory session store with JSON file persistence and delete tombstones."""

from __future__ import annotations

import json
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from app.core.paths import data_dir
from app.core.schemas import ChatMessage, SessionDetail, SessionSummary, SessionUpsert

_LOCK = threading.Lock()
_SESSIONS: dict[str, dict] = {}
_TOMBSTONES: set[str] = set()
_LOADED = False


def _store_path() -> Path:
    return data_dir() / "sessions.json"


def _tombstone_path() -> Path:
    return data_dir() / "session_tombstones.json"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _norm_id(session_id: str | None) -> str:
    """Normalize IDs — macOS UUID.uuidString is uppercase; Python uuid4() is lowercase."""
    if not session_id:
        return str(uuid.uuid4())
    return session_id.strip().lower()


def _sanitize_message_dict(msg: dict) -> dict:
    from app.providers.messages import persist_inline_images

    content = msg.get("content") or ""
    # Persist generated images to disk (file:// link) rather than dropping them, so
    # they survive restarts. Non-image content is returned unchanged.
    cleaned = persist_inline_images(content)
    if cleaned == content:
        return msg
    out = dict(msg)
    out["content"] = cleaned
    return out


def _sanitize_row(row: dict) -> tuple[dict, bool]:
    msgs = row.get("messages") or []
    cleaned = [_sanitize_message_dict(m) if isinstance(m, dict) else m for m in msgs]
    dirty = cleaned != msgs
    if not dirty:
        return row, False
    out = dict(row)
    out["messages"] = cleaned
    return out, True


def _ensure_loaded() -> None:
    """Load once per process — even when the session map is empty after deletes."""
    global _SESSIONS, _TOMBSTONES, _LOADED
    if _LOADED:
        return
    data_dir().mkdir(parents=True, exist_ok=True)
    if _store_path().exists():
        try:
            raw = json.loads(_store_path().read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                if "sessions" in raw and isinstance(raw["sessions"], dict):
                    raw_sessions = raw["sessions"]
                else:
                    raw_sessions = {k: v for k, v in raw.items() if isinstance(v, dict)}
                # Normalize keys to lowercase (merge any case duplicates)
                normalized: dict[str, dict] = {}
                for key, row in raw_sessions.items():
                    normalized[_norm_id(key)] = row
                _SESSIONS = normalized
        except (json.JSONDecodeError, OSError):
            _SESSIONS = {}
    if _tombstone_path().exists():
        try:
            raw_t = json.loads(_tombstone_path().read_text(encoding="utf-8"))
            if isinstance(raw_t, list):
                _TOMBSTONES = {_norm_id(str(x)) for x in raw_t if str(x).strip()}
        except (json.JSONDecodeError, OSError):
            _TOMBSTONES = set()
    dirty = False
    for sid in list(_SESSIONS.keys()):
        if sid in _TOMBSTONES:
            del _SESSIONS[sid]
            dirty = True
            continue
        cleaned_row, row_dirty = _sanitize_row(_SESSIONS[sid])
        if row_dirty:
            _SESSIONS[sid] = cleaned_row
            dirty = True
        msgs = list((_SESSIONS[sid].get("messages") or []))
        deduped = _dedupe_messages(msgs)
        if deduped != msgs:
            _SESSIONS[sid] = dict(_SESSIONS[sid])
            _SESSIONS[sid]["messages"] = deduped
            dirty = True
    _LOADED = True
    if dirty:
        _persist()


def _persist() -> None:
    data_dir().mkdir(parents=True, exist_ok=True)
    _store_path().write_text(json.dumps(_SESSIONS, indent=2), encoding="utf-8")
    _tombstone_path().write_text(
        json.dumps(sorted(_TOMBSTONES), indent=2),
        encoding="utf-8",
    )


def list_sessions() -> list[SessionSummary]:
    with _LOCK:
        _ensure_loaded()
        rows = []
        for sid, row in _SESSIONS.items():
            if sid in _TOMBSTONES:
                continue
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
        sid = _norm_id(session_id)
        if sid in _TOMBSTONES:
            return None
        row = _SESSIONS.get(sid)
        if not row:
            return None
        messages = [ChatMessage(**m) for m in _dedupe_messages(list(row.get("messages") or []))]
        return SessionDetail(
            id=sid,
            title=row.get("title") or "Untitled",
            updated_at=row.get("updated_at") or _now(),
            messages=messages,
        )


def _norm_content(content: str | None) -> str:
    """Collapse cost footers / whitespace for turn dedupe comparisons."""
    import re

    text = content or ""
    text = re.sub(
        r"\n?\s*\[\s*[^\]]*tokens used[^\]]*cost\s*=\s*\$[0-9.]+\s*\]\s*$",
        "",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(r"!\[[^\]]*\]\(file://[^)]+\)", "![img](file)", text, flags=re.IGNORECASE)
    text = re.sub(r"!\[[^\]]*\]\(data:image/[^)]+\)", "![img](data)", text, flags=re.IGNORECASE)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _content_richness(content: str | None) -> int:
    text = content or ""
    body = _norm_content(text)
    if not body:
        return 0
    score = min(len(body), 50_000)
    if "file://" in text:
        score += 100_000
    if "data:image" in text:
        score += 40_000
    if "<svg" in text.lower():
        score += 20_000
    return score


def _dedupe_messages(msgs: list[dict]) -> list[dict]:
    """Collapse consecutive identical turns and duplicated user→assistant pairs."""
    out: list[dict] = []
    for msg in msgs:
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        content = msg.get("content") or ""
        if (
            out
            and out[-1].get("role") == role
            and _norm_content(out[-1].get("content")) == _norm_content(content)
        ):
            if _content_richness(content) > _content_richness(out[-1].get("content")):
                out[-1] = msg
            continue
        if (
            role == "assistant"
            and len(out) >= 3
            and out[-1].get("role") == "user"
            and out[-2].get("role") == "assistant"
            and out[-3].get("role") == "user"
        ):
            dup_user = out[-1]
            prev_asst = out[-2]
            prev_user = out[-3]
            if _norm_content(dup_user.get("content")) == _norm_content(prev_user.get("content")) and _norm_content(
                content
            ) == _norm_content(prev_asst.get("content")):
                if _content_richness(content) > _content_richness(prev_asst.get("content")):
                    out[-2] = msg
                out.pop()
                continue
        out.append(msg)
    return out


def upsert_session(payload: SessionUpsert) -> SessionDetail | None:
    with _LOCK:
        _ensure_loaded()
        sid = _norm_id(payload.id) if payload.id else str(uuid.uuid4())
        # Do not resurrect a deleted session via late chat/compare upserts.
        if sid in _TOMBSTONES:
            return None
        new_msgs = _dedupe_messages(
            [_sanitize_message_dict(m.model_dump()) for m in payload.messages]
        )
        existing = _SESSIONS.get(sid)
        old_msgs = _dedupe_messages(list((existing or {}).get("messages") or []))
        # Prefer the longer unique history. Equal length → prefer the client payload
        # (often has file:// images the gateway already normalized the same way).
        if old_msgs and len(new_msgs) < len(old_msgs):
            new_msgs = old_msgs
        row = {
            "title": payload.title or (existing or {}).get("title") or "Untitled",
            "updated_at": _now(),
            "messages": new_msgs,
        }
        _SESSIONS[sid] = row
        _persist()
        return SessionDetail(
            id=sid,
            title=row["title"],
            updated_at=row["updated_at"],
            messages=[ChatMessage(**m) for m in new_msgs],
        )


def record_chat_turn(
    session_id: str,
    *,
    title: str | None,
    user_content: str,
    assistant_content: str,
) -> SessionDetail | None:
    """Append one user/assistant turn without replacing prior history."""
    from app.providers.messages import persist_inline_images

    with _LOCK:
        _ensure_loaded()
        sid = _norm_id(session_id)
        if sid in _TOMBSTONES:
            return None
        # Keep generated images by persisting them to disk (file:// link) rather than
        # dropping to a placeholder, so they survive an app restart.
        user_content = persist_inline_images(user_content or "")
        assistant_content = persist_inline_images(assistant_content or "")
        row = _SESSIONS.get(sid) or {
            "title": title or "New session",
            "updated_at": _now(),
            "messages": [],
        }
        if title:
            row["title"] = title
        msgs = _dedupe_messages(list(row.get("messages") or []))
        # Drop trailing empty assistant placeholders
        while msgs and msgs[-1].get("role") == "assistant" and not str(
            msgs[-1].get("content") or ""
        ).strip():
            msgs.pop()
        # Already recorded this exact turn (stream + upsert / retry races).
        if (
            len(msgs) >= 2
            and msgs[-2].get("role") == "user"
            and msgs[-1].get("role") == "assistant"
            and _norm_content(msgs[-2].get("content")) == _norm_content(user_content)
            and _norm_content(msgs[-1].get("content")) == _norm_content(assistant_content)
        ):
            if _content_richness(assistant_content) > _content_richness(msgs[-1].get("content")):
                msgs[-1] = {"role": "assistant", "content": assistant_content}
                row["messages"] = msgs
                row["updated_at"] = _now()
                _SESSIONS[sid] = row
                _persist()
            return SessionDetail(
                id=sid,
                title=row.get("title") or "New session",
                updated_at=row.get("updated_at") or _now(),
                messages=[ChatMessage(**m) for m in msgs],
            )
        if not (
            msgs
            and msgs[-1].get("role") == "user"
            and _norm_content(msgs[-1].get("content")) == _norm_content(user_content)
        ):
            msgs.append({"role": "user", "content": user_content})
        msgs.append({"role": "assistant", "content": assistant_content})
        msgs = _dedupe_messages(msgs)
        row["messages"] = msgs
        row["updated_at"] = _now()
        _SESSIONS[sid] = row
        _persist()
        return SessionDetail(
            id=sid,
            title=row["title"],
            updated_at=row["updated_at"],
            messages=[ChatMessage(**m) for m in msgs],
        )


def append_turn(
    session_id: str,
    *,
    title: str | None,
    user: ChatMessage | None,
    assistant: ChatMessage | None,
) -> SessionDetail | None:
    with _LOCK:
        _ensure_loaded()
        sid = _norm_id(session_id)
        if sid in _TOMBSTONES:
            return None
        row = _SESSIONS.get(sid) or {
            "title": title or "New session",
            "updated_at": _now(),
            "messages": [],
        }
        if title:
            row["title"] = title
        msgs = list(row.get("messages") or [])
        if user:
            msgs.append(_sanitize_message_dict(user.model_dump()))
        if assistant:
            msgs.append(_sanitize_message_dict(assistant.model_dump()))
        row["messages"] = msgs
        row["updated_at"] = _now()
        _SESSIONS[sid] = row
        _persist()
        return SessionDetail(
            id=sid,
            title=row["title"],
            updated_at=row["updated_at"],
            messages=[ChatMessage(**m) for m in msgs],
        )


def delete_session(session_id: str) -> bool:
    with _LOCK:
        _ensure_loaded()
        sid = _norm_id(session_id)
        _TOMBSTONES.add(sid)
        # Remove any casing variant of the same UUID.
        removed = False
        for key in list(_SESSIONS.keys()):
            if key == sid or key.lower() == sid:
                del _SESSIONS[key]
                removed = True
        _persist()
        return True if removed or sid in _TOMBSTONES else False


def delete_all_sessions() -> int:
    with _LOCK:
        _ensure_loaded()
        count = len(_SESSIONS)
        for sid in list(_SESSIONS.keys()):
            _TOMBSTONES.add(_norm_id(sid))
        _SESSIONS.clear()
        _persist()
        return count


def is_deleted(session_id: str) -> bool:
    with _LOCK:
        _ensure_loaded()
        return _norm_id(session_id) in _TOMBSTONES
