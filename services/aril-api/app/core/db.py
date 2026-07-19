"""SQLite persistence for judgements, analysis cache, and chat transactions."""

from __future__ import annotations

import json
import os
import sqlite3
import threading
from pathlib import Path
from typing import Any, Iterable

from app.core.config import settings
from app.core.paths import data_dir

_LOCK = threading.RLock()
_CONN: sqlite3.Connection | None = None
_MIGRATED = False

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS classifications (
  id TEXT PRIMARY KEY,
  prompt TEXT NOT NULL DEFAULT '',
  prompt_snippet TEXT NOT NULL DEFAULT '',
  fingerprint TEXT NOT NULL UNIQUE,
  category TEXT NOT NULL,
  model TEXT NOT NULL,
  accuracy REAL,
  category_overridden INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS category_wins (
  category TEXT NOT NULL,
  model TEXT NOT NULL,
  wins INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (category, model)
);

CREATE TABLE IF NOT EXISTS fingerprint_wins (
  fingerprint TEXT NOT NULL,
  model TEXT NOT NULL,
  wins INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (fingerprint, model)
);

CREATE TABLE IF NOT EXISTS analysis_cache (
  id TEXT PRIMARY KEY,
  fingerprint TEXT NOT NULL,
  context_hash TEXT NOT NULL,
  prompt_snippet TEXT NOT NULL DEFAULT '',
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(fingerprint, context_hash)
);

CREATE TABLE IF NOT EXISTS chat_transactions (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  prompt TEXT NOT NULL DEFAULT '',
  prompt_snippet TEXT NOT NULL DEFAULT '',
  fingerprint TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  category TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cost_usd REAL,
  cached INTEGER NOT NULL DEFAULT 0,
  analysis_json TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_classifications_created ON classifications(created_at);
CREATE INDEX IF NOT EXISTS idx_analysis_cache_created ON analysis_cache(created_at);
CREATE INDEX IF NOT EXISTS idx_chat_tx_created ON chat_transactions(created_at);
"""

# Tables subject to FIFO retention (oldest created_at first).
_FIFO_TABLES = ("classifications", "analysis_cache", "chat_transactions")


def db_path() -> Path:
    return data_dir() / "aril.db"


def status(*, probe: bool = True) -> dict[str, Any]:
    """Return SQLite readiness, path, and lightweight integrity probe results."""
    from datetime import datetime, timezone

    path = db_path()
    absolute = str(path.resolve()) if path.exists() or path.parent.exists() else str(path)
    exists = path.exists()
    size_bytes = int(path.stat().st_size) if exists else 0
    writable = False
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        writable = os.access(path.parent, os.W_OK) and (not exists or os.access(path, os.W_OK))
    except OSError:
        writable = False

    ready = False
    message = "Database not ready"
    counts_map: dict[str, int] = {}
    retention = max(1, int(settings.aril_sqlite_retention))

    if probe:
        try:
            conn = connect()
            conn.execute("SELECT 1")
            for table in _FIFO_TABLES:
                conn.execute(f"SELECT 1 FROM {table} LIMIT 1")
            counts_map = counts()
            retention = get_retention()
            ready = exists and writable
            if not exists:
                # connect() creates the file — re-check
                exists = path.exists()
                size_bytes = int(path.stat().st_size) if exists else 0
                ready = exists and writable
            message = "Database ready" if ready else "Database file missing or not writable"
        except Exception as exc:  # noqa: BLE001
            ready = False
            message = f"Database check failed: {exc}"
    else:
        message = "Probe skipped"

    return {
        "ready": ready,
        "engine": "sqlite",
        "path": str(path),
        "absolute_path": absolute,
        "exists": exists,
        "writable": writable,
        "size_bytes": size_bytes,
        "retention": retention,
        "counts": counts_map,
        "total": int(sum(counts_map.values())),
        "message": message,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


def connect() -> sqlite3.Connection:
    global _CONN
    with _LOCK:
        if _CONN is not None:
            return _CONN
        path = db_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(path), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.executescript(_SCHEMA)
        _CONN = conn
        _maybe_migrate_json(conn)
        return conn


def reset_connection() -> None:
    """Test helper: close and forget the shared connection."""
    global _CONN, _MIGRATED
    with _LOCK:
        if _CONN is not None:
            try:
                _CONN.close()
            except sqlite3.Error:
                pass
        _CONN = None
        _MIGRATED = False


def get_meta(key: str, default: str | None = None) -> str | None:
    conn = connect()
    with _LOCK:
        row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return str(row["value"]) if row else default


def set_meta(key: str, value: str) -> None:
    conn = connect()
    with _LOCK:
        conn.execute(
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
        conn.commit()


def get_retention() -> int:
    """Effective FIFO retention (DB override, else settings default)."""
    raw = get_meta("sqlite_retention")
    if raw is not None:
        try:
            return max(1, int(raw))
        except ValueError:
            pass
    return max(1, int(settings.aril_sqlite_retention))


def set_retention(limit: int) -> int:
    limit = max(1, int(limit))
    set_meta("sqlite_retention", str(limit))
    # Apply immediately so lowering the cap trims old rows now.
    with _LOCK:
        conn = connect()
        for table in _FIFO_TABLES:
            _fifo_trim(conn, table, limit)
        conn.commit()
    return limit


def fifo_trim(table: str) -> None:
    if table not in _FIFO_TABLES:
        raise ValueError(f"Unknown FIFO table: {table}")
    with _LOCK:
        conn = connect()
        _fifo_trim(conn, table, get_retention())
        conn.commit()


def _fifo_trim(conn: sqlite3.Connection, table: str, limit: int) -> None:
    count = conn.execute(f"SELECT COUNT(*) AS c FROM {table}").fetchone()["c"]
    if count <= limit:
        return
    excess = int(count) - limit
    conn.execute(
        f"""
        DELETE FROM {table}
        WHERE id IN (
          SELECT id FROM {table}
          ORDER BY created_at ASC, id ASC
          LIMIT ?
        )
        """,
        (excess,),
    )


def counts() -> dict[str, int]:
    conn = connect()
    with _LOCK:
        out: dict[str, int] = {}
        for table in _FIFO_TABLES:
            out[table] = int(conn.execute(f"SELECT COUNT(*) AS c FROM {table}").fetchone()["c"])
        return out


def list_store_records() -> list[dict[str, Any]]:
    """Unified Learning browser: judgements, analysis cache, chat transactions."""
    conn = connect()
    with _LOCK:
        rows: list[dict[str, Any]] = []
        for row in conn.execute(
            """
            SELECT id, prompt_snippet, fingerprint, category, model,
                   accuracy, category_overridden, created_at, updated_at
            FROM classifications
            ORDER BY created_at DESC
            """
        ):
            rows.append(
                {
                    "id": row["id"],
                    "kind": "judgement",
                    "prompt_snippet": row["prompt_snippet"] or "",
                    "fingerprint": row["fingerprint"] or "",
                    "category": row["category"],
                    "model": row["model"],
                    "accuracy": row["accuracy"],
                    "category_overridden": bool(row["category_overridden"]),
                    "cached": None,
                    "cost_usd": None,
                    "session_id": None,
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                }
            )
        for row in conn.execute(
            """
            SELECT id, prompt_snippet, fingerprint, created_at, updated_at, payload_json
            FROM analysis_cache
            ORDER BY created_at DESC
            """
        ):
            payload: dict[str, Any] = {}
            try:
                payload = json.loads(row["payload_json"] or "{}")
            except json.JSONDecodeError:
                payload = {}
            rows.append(
                {
                    "id": row["id"],
                    "kind": "analysis_cache",
                    "prompt_snippet": row["prompt_snippet"] or "",
                    "fingerprint": row["fingerprint"] or "",
                    "category": payload.get("category"),
                    "model": payload.get("recommended_model") or payload.get("model"),
                    "accuracy": None,
                    "category_overridden": None,
                    "cached": True,
                    "cost_usd": None,
                    "session_id": None,
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                }
            )
        for row in conn.execute(
            """
            SELECT id, session_id, prompt_snippet, fingerprint, model, category,
                   input_tokens, output_tokens, cost_usd, cached, created_at
            FROM chat_transactions
            ORDER BY created_at DESC
            """
        ):
            rows.append(
                {
                    "id": row["id"],
                    "kind": "chat_transaction",
                    "prompt_snippet": row["prompt_snippet"] or "",
                    "fingerprint": row["fingerprint"] or "",
                    "category": row["category"],
                    "model": row["model"],
                    "accuracy": None,
                    "category_overridden": None,
                    "cached": bool(row["cached"]),
                    "cost_usd": row["cost_usd"],
                    "input_tokens": row["input_tokens"],
                    "output_tokens": row["output_tokens"],
                    "session_id": row["session_id"],
                    "created_at": row["created_at"],
                    "updated_at": row["created_at"],
                }
            )
        rows.sort(key=lambda r: r.get("created_at") or "", reverse=True)
        return rows


def delete_store_record(record_id: str) -> str | None:
    """Delete one record by id. Returns kind deleted, or None if missing."""
    conn = connect()
    with _LOCK:
        for table, kind in (
            ("classifications", "judgement"),
            ("analysis_cache", "analysis_cache"),
            ("chat_transactions", "chat_transaction"),
        ):
            cur = conn.execute(f"DELETE FROM {table} WHERE id = ?", (record_id,))
            if cur.rowcount:
                conn.commit()
                return kind
        return None


def delete_all_store_records(include_wins: bool = False) -> dict[str, int]:
    """Delete all FIFO store rows. Also clears Prefer win aggregates when requested."""
    conn = connect()
    with _LOCK:
        deleted: dict[str, int] = {}
        tables = list(_FIFO_TABLES)
        if include_wins:
            tables += ["category_wins", "fingerprint_wins"]
        for table in tables:
            deleted[table] = int(conn.execute(f"SELECT COUNT(*) AS c FROM {table}").fetchone()["c"])
            conn.execute(f"DELETE FROM {table}")
        conn.commit()
        return deleted


def _maybe_migrate_json(conn: sqlite3.Connection) -> None:
    """Import legacy preferences.json into SQLite (idempotent upsert)."""
    global _MIGRATED
    prefs_path = data_dir() / "preferences.json"
    if prefs_path.exists():
        try:
            raw = json.loads(prefs_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            raw = {}
        if isinstance(raw, dict):
            for entry in raw.get("classifications") or []:
                if not isinstance(entry, dict) or not entry.get("fingerprint"):
                    continue
                now = entry.get("updated_at") or entry.get("created_at") or ""
                conn.execute(
                    """
                    INSERT INTO classifications(
                      id, prompt, prompt_snippet, fingerprint, category, model,
                      accuracy, category_overridden, created_at, updated_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(fingerprint) DO UPDATE SET
                      prompt = excluded.prompt,
                      prompt_snippet = excluded.prompt_snippet,
                      category = excluded.category,
                      model = excluded.model,
                      accuracy = COALESCE(excluded.accuracy, classifications.accuracy),
                      category_overridden = MAX(
                        classifications.category_overridden,
                        excluded.category_overridden
                      ),
                      updated_at = CASE
                        WHEN excluded.updated_at > classifications.updated_at
                        THEN excluded.updated_at
                        ELSE classifications.updated_at
                      END
                    """,
                    (
                        entry.get("id") or str(__import__("uuid").uuid4()),
                        entry.get("prompt") or "",
                        entry.get("prompt_snippet") or "",
                        entry.get("fingerprint") or "general",
                        entry.get("category") or "general",
                        entry.get("model") or "",
                        entry.get("accuracy"),
                        1 if entry.get("category_overridden") else 0,
                        entry.get("created_at") or now,
                        now,
                    ),
                )
            for cat, models in (raw.get("category_wins") or {}).items():
                if not isinstance(models, dict):
                    continue
                for model, wins in models.items():
                    conn.execute(
                        """
                        INSERT INTO category_wins(category, model, wins) VALUES(?,?,?)
                        ON CONFLICT(category, model) DO UPDATE
                          SET wins = CASE
                            WHEN excluded.wins > category_wins.wins THEN excluded.wins
                            ELSE category_wins.wins
                          END
                        """,
                        (cat, model, int(wins or 0)),
                    )
            for fp, models in (raw.get("fingerprint_wins") or {}).items():
                if not isinstance(models, dict):
                    continue
                for model, wins in models.items():
                    conn.execute(
                        """
                        INSERT INTO fingerprint_wins(fingerprint, model, wins) VALUES(?,?,?)
                        ON CONFLICT(fingerprint, model) DO UPDATE
                          SET wins = CASE
                            WHEN excluded.wins > fingerprint_wins.wins THEN excluded.wins
                            ELSE fingerprint_wins.wins
                          END
                        """,
                        (fp, model, int(wins or 0)),
                    )

    conn.execute(
        "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        ("json_migrated", "1"),
    )
    # Trim after import if over default retention.
    limit = max(1, int(settings.aril_sqlite_retention))
    for table in _FIFO_TABLES:
        _fifo_trim(conn, table, limit)
    conn.commit()
    _MIGRATED = True


def rows_to_dicts(rows: Iterable[sqlite3.Row]) -> list[dict[str, Any]]:
    return [dict(r) for r in rows]
