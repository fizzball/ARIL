"""Preference learning from compare winners and user classification overrides (SQLite)."""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from typing import Any

from app.core import db as store


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def fingerprint(prompt: str) -> str:
    tokens = re.findall(r"[a-z0-9]{3,}", prompt.lower())
    uniq = sorted(set(tokens))[:24]
    return "|".join(uniq) if uniq else "general"


def _row_to_classification(row: Any) -> dict[str, Any]:
    return {
        "id": row["id"],
        "prompt": row["prompt"] or "",
        "prompt_snippet": row["prompt_snippet"] or "",
        "fingerprint": row["fingerprint"],
        "category": row["category"],
        "model": row["model"],
        "accuracy": row["accuracy"],
        "category_overridden": bool(row["category_overridden"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def record_preference(
    *,
    prompt: str,
    category: str,
    model: str,
    accuracy: float | None = None,
    category_overridden: bool = False,
    count_wins: bool = True,
) -> dict:
    with store._LOCK:
        conn = store.connect()
        fp = fingerprint(prompt)
        snippet = (prompt or "").strip().replace("\n", " ")[:120]
        now = _now()

        if count_wins:
            conn.execute(
                """
                INSERT INTO category_wins(category, model, wins) VALUES(?,?,1)
                ON CONFLICT(category, model) DO UPDATE SET wins = wins + 1
                """,
                (category, model),
            )
            conn.execute(
                """
                INSERT INTO fingerprint_wins(fingerprint, model, wins) VALUES(?,?,1)
                ON CONFLICT(fingerprint, model) DO UPDATE SET wins = wins + 1
                """,
                (fp, model),
            )

        existing = conn.execute(
            "SELECT * FROM classifications WHERE fingerprint = ?", (fp,)
        ).fetchone()
        if existing:
            new_overridden = bool(
                category_overridden or existing["category_overridden"]
            )
            new_accuracy = (
                float(accuracy) if accuracy is not None else existing["accuracy"]
            )
            conn.execute(
                """
                UPDATE classifications
                SET prompt = ?, prompt_snippet = ?, category = ?, model = ?,
                    accuracy = ?, category_overridden = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    prompt,
                    snippet,
                    category,
                    model,
                    new_accuracy,
                    1 if new_overridden else 0,
                    now,
                    existing["id"],
                ),
            )
            classification_id = existing["id"]
            class_accuracy = new_accuracy
            class_overridden = new_overridden
        else:
            classification_id = str(uuid.uuid4())
            class_accuracy = float(accuracy) if accuracy is not None else None
            class_overridden = bool(category_overridden)
            conn.execute(
                """
                INSERT INTO classifications(
                  id, prompt, prompt_snippet, fingerprint, category, model,
                  accuracy, category_overridden, created_at, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    classification_id,
                    prompt,
                    snippet,
                    fp,
                    category,
                    model,
                    class_accuracy,
                    1 if class_overridden else 0,
                    now,
                    now,
                ),
            )
            store._fifo_trim(conn, "classifications", store.get_retention())

        cat_wins = 0
        fp_wins = 0
        cat_row = conn.execute(
            "SELECT wins FROM category_wins WHERE category = ? AND model = ?",
            (category, model),
        ).fetchone()
        if cat_row:
            cat_wins = int(cat_row["wins"])
        fp_row = conn.execute(
            "SELECT wins FROM fingerprint_wins WHERE fingerprint = ? AND model = ?",
            (fp, model),
        ).fetchone()
        if fp_row:
            fp_wins = int(fp_row["wins"])
        conn.commit()

        return {
            "category": category,
            "fingerprint": fp,
            "model": model,
            "category_wins": cat_wins,
            "fingerprint_wins": fp_wins,
            "classification_id": classification_id,
            "accuracy": class_accuracy,
            "category_overridden": class_overridden,
        }


def lookup_classification(prompt: str) -> dict | None:
    with store._LOCK:
        conn = store.connect()
        fp = fingerprint(prompt)
        row = conn.execute(
            "SELECT * FROM classifications WHERE fingerprint = ?", (fp,)
        ).fetchone()
        return _row_to_classification(row) if row else None


def ensure_auto_judgement(
    *,
    prompt: str,
    category: str,
    model: str,
) -> dict | None:
    """Create a Learning judgement on first successful Auto send for this fingerprint.

    Does not overwrite an existing Prefer / Analysis judgement. Does **not**
    increment Prefer win counters (so Auto does not train on itself).
    Callers must not invoke this for Manual mode.
    """
    if not (prompt or "").strip():
        return None
    if lookup_classification(prompt):
        return None
    return record_preference(
        prompt=prompt,
        category=category,
        model=model,
        accuracy=None,
        category_overridden=False,
        count_wins=False,
    )


_CATEGORY_LABELS: dict[str, str] = {
    "coding": "Coding",
    "security": "Security",
    "reasoning": "Reasoning",
    "vision": "Vision",
    "cost": "Cost",
    "performance": "Performance",
    "confidence": "Confidence",
    "general": "General",
}


def _category_label(category: str) -> str:
    key = (category or "").strip().lower()
    return _CATEGORY_LABELS.get(key, (category or "General").strip().title() or "General")


def preferred_model_for_prompt(prompt: str, category: str) -> dict[str, str] | None:
    """Pick a model from real Prefer wins (fingerprint, then category).

    Ignores Auto-seeded judgements (those do not increment win tables).
    Returns ``{model, reason, source}`` or ``None``.
    """
    cat = (category or "general").strip().lower() or "general"
    label = _category_label(cat)
    with store._LOCK:
        conn = store.connect()
        fp = fingerprint(prompt)

        fp_rows = conn.execute(
            """
            SELECT model, wins FROM fingerprint_wins
            WHERE fingerprint = ?
            ORDER BY wins DESC, model ASC
            """,
            (fp,),
        ).fetchall()
        if fp_rows and int(fp_rows[0]["wins"]) >= 1:
            model = str(fp_rows[0]["model"])
            return {
                "model": model,
                "reason": f"Because you preferred {model} for a similar prompt ({label}).",
                "source": "fingerprint",
            }

        cat_rows = conn.execute(
            """
            SELECT model, wins FROM category_wins
            WHERE category = ?
            ORDER BY wins DESC, model ASC
            """,
            (cat,),
        ).fetchall()
        if not cat_rows or int(cat_rows[0]["wins"]) < 1:
            return None
        top_wins = int(cat_rows[0]["wins"])
        # Require a clear winner when there is a tie at the top.
        if len(cat_rows) > 1 and int(cat_rows[1]["wins"]) == top_wins:
            return None
        model = str(cat_rows[0]["model"])
        return {
            "model": model,
            "reason": f"Because you preferred {model} for {label}.",
            "source": "category",
        }


def confidence_boost(prompt: str, category: str, model: str) -> float:
    """0..0.40 boost applied to route score (wins + accuracy)."""
    with store._LOCK:
        conn = store.connect()
        cat_row = conn.execute(
            "SELECT wins FROM category_wins WHERE category = ? AND model = ?",
            (category, model),
        ).fetchone()
        cat_wins = int(cat_row["wins"]) if cat_row else 0
        fp = fingerprint(prompt)
        fp_row = conn.execute(
            "SELECT wins FROM fingerprint_wins WHERE fingerprint = ? AND model = ?",
            (fp, model),
        ).fetchone()
        fp_wins = int(fp_row["wins"]) if fp_row else 0
        boost = min(0.2, cat_wins * 0.04) + min(0.15, fp_wins * 0.05)
        entry = conn.execute(
            "SELECT * FROM classifications WHERE fingerprint = ?", (fp,)
        ).fetchone()
        if entry and entry["model"] == model and entry["accuracy"] is not None:
            boost += 0.05 * float(entry["accuracy"])
        return round(min(0.4, boost), 3)


def list_classifications() -> list[dict]:
    with store._LOCK:
        conn = store.connect()
        rows = conn.execute(
            "SELECT * FROM classifications ORDER BY updated_at DESC, created_at DESC"
        ).fetchall()
        return [_row_to_classification(r) for r in rows]


def update_classification(
    classification_id: str,
    *,
    category: str | None = None,
    accuracy: float | None = None,
    model: str | None = None,
    remove_accuracy: bool = False,
) -> dict | None:
    with store._LOCK:
        conn = store.connect()
        entry = conn.execute(
            "SELECT * FROM classifications WHERE id = ?", (classification_id,)
        ).fetchone()
        if not entry:
            return None

        new_category = entry["category"]
        new_model = entry["model"]
        new_accuracy = entry["accuracy"]
        overridden = bool(entry["category_overridden"])

        if category is not None and category != entry["category"]:
            new_category = category
            overridden = True
            mid = model or entry["model"]
            if mid:
                conn.execute(
                    """
                    INSERT INTO category_wins(category, model, wins) VALUES(?,?,1)
                    ON CONFLICT(category, model) DO UPDATE SET wins = wins + 1
                    """,
                    (category, mid),
                )
        if model is not None:
            new_model = model
        if remove_accuracy:
            new_accuracy = None
        elif accuracy is not None:
            new_accuracy = float(accuracy)

        now = _now()
        conn.execute(
            """
            UPDATE classifications
            SET category = ?, model = ?, accuracy = ?, category_overridden = ?, updated_at = ?
            WHERE id = ?
            """,
            (
                new_category,
                new_model,
                new_accuracy,
                1 if overridden else 0,
                now,
                classification_id,
            ),
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM classifications WHERE id = ?", (classification_id,)
        ).fetchone()
        return _row_to_classification(row) if row else None


def delete_classification(classification_id: str) -> bool:
    with store._LOCK:
        conn = store.connect()
        cur = conn.execute(
            "DELETE FROM classifications WHERE id = ?", (classification_id,)
        )
        conn.commit()
        return cur.rowcount > 0


def delete_all_classifications() -> int:
    with store._LOCK:
        conn = store.connect()
        count = int(
            conn.execute("SELECT COUNT(*) AS c FROM classifications").fetchone()["c"]
        )
        conn.execute("DELETE FROM classifications")
        conn.commit()
        return count


def snapshot() -> dict:
    with store._LOCK:
        conn = store.connect()
        classifications = [
            _row_to_classification(r)
            for r in conn.execute(
                "SELECT * FROM classifications ORDER BY updated_at DESC"
            ).fetchall()
        ]
        category_wins: dict[str, dict[str, int]] = {}
        for row in conn.execute("SELECT category, model, wins FROM category_wins"):
            category_wins.setdefault(row["category"], {})[row["model"]] = int(row["wins"])
        fingerprint_wins: dict[str, dict[str, int]] = {}
        for row in conn.execute(
            "SELECT fingerprint, model, wins FROM fingerprint_wins"
        ):
            fingerprint_wins.setdefault(row["fingerprint"], {})[row["model"]] = int(
                row["wins"]
            )
        return {
            "category_wins": category_wins,
            "fingerprint_wins": fingerprint_wins,
            "classifications": classifications,
        }
