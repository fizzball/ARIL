"""Cached analysis parameters for like prompts (fingerprint + context hash)."""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timezone
from typing import Any

from app.core import db as store
from app.core import preferences as pref_store


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def context_hash(
    *,
    routing_profile: dict | None,
    system_prompt: str | None,
    enhance_alternatives: bool,
) -> str:
    payload = {
        "routing_profile": routing_profile or {},
        "system_prompt": (system_prompt or "").strip(),
        "enhance_alternatives": bool(enhance_alternatives),
    }
    raw = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def get(
    prompt: str,
    *,
    routing_profile: dict | None = None,
    system_prompt: str | None = None,
    enhance_alternatives: bool = True,
) -> dict[str, Any] | None:
    fp = pref_store.fingerprint(prompt)
    ch = context_hash(
        routing_profile=routing_profile,
        system_prompt=system_prompt,
        enhance_alternatives=enhance_alternatives,
    )
    with store._LOCK:
        conn = store.connect()
        row = conn.execute(
            """
            SELECT id, fingerprint, context_hash, prompt_snippet, payload_json,
                   created_at, updated_at
            FROM analysis_cache
            WHERE fingerprint = ? AND context_hash = ?
            """,
            (fp, ch),
        ).fetchone()
        if not row:
            return None
        try:
            payload = json.loads(row["payload_json"] or "{}")
        except json.JSONDecodeError:
            return None
        return {
            "id": row["id"],
            "fingerprint": row["fingerprint"],
            "context_hash": row["context_hash"],
            "prompt_snippet": row["prompt_snippet"],
            "payload": payload,
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }


def put(
    prompt: str,
    payload: dict[str, Any],
    *,
    routing_profile: dict | None = None,
    system_prompt: str | None = None,
    enhance_alternatives: bool = True,
) -> dict[str, Any]:
    fp = pref_store.fingerprint(prompt)
    ch = context_hash(
        routing_profile=routing_profile,
        system_prompt=system_prompt,
        enhance_alternatives=enhance_alternatives,
    )
    snippet = (prompt or "").strip().replace("\n", " ")[:120]
    now = _now()
    body = json.dumps(payload, ensure_ascii=False)

    with store._LOCK:
        conn = store.connect()
        existing = conn.execute(
            """
            SELECT id FROM analysis_cache
            WHERE fingerprint = ? AND context_hash = ?
            """,
            (fp, ch),
        ).fetchone()
        if existing:
            conn.execute(
                """
                UPDATE analysis_cache
                SET prompt_snippet = ?, payload_json = ?, updated_at = ?
                WHERE id = ?
                """,
                (snippet, body, now, existing["id"]),
            )
            record_id = existing["id"]
        else:
            record_id = str(uuid.uuid4())
            conn.execute(
                """
                INSERT INTO analysis_cache(
                  id, fingerprint, context_hash, prompt_snippet,
                  payload_json, created_at, updated_at
                ) VALUES(?,?,?,?,?,?,?)
                """,
                (record_id, fp, ch, snippet, body, now, now),
            )
            store._fifo_trim(conn, "analysis_cache", store.get_retention())
        conn.commit()
        return {
            "id": record_id,
            "fingerprint": fp,
            "context_hash": ch,
            "prompt_snippet": snippet,
        }


def record_chat_transaction(
    *,
    session_id: str | None,
    prompt: str,
    model: str,
    category: str | None,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    cost_usd: float | None = None,
    cached: bool = False,
    analysis: dict[str, Any] | None = None,
) -> dict[str, Any]:
    fp = pref_store.fingerprint(prompt)
    snippet = (prompt or "").strip().replace("\n", " ")[:120]
    now = _now()
    record_id = str(uuid.uuid4())
    analysis_json = json.dumps(analysis, ensure_ascii=False) if analysis else None

    with store._LOCK:
        conn = store.connect()
        conn.execute(
            """
            INSERT INTO chat_transactions(
              id, session_id, prompt, prompt_snippet, fingerprint, model, category,
              input_tokens, output_tokens, cost_usd, cached, analysis_json, created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                record_id,
                session_id,
                prompt or "",
                snippet,
                fp,
                model or "",
                category,
                input_tokens,
                output_tokens,
                cost_usd,
                1 if cached else 0,
                analysis_json,
                now,
            ),
        )
        store._fifo_trim(conn, "chat_transactions", store.get_retention())
        conn.commit()
        return {
            "id": record_id,
            "fingerprint": fp,
            "prompt_snippet": snippet,
            "created_at": now,
        }
