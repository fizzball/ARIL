"""SQLite store / FIFO retention tests (isolated temp data dir)."""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

# Point store at a temp dir before importing app modules that open the DB.
@pytest.fixture()
def isolated_store(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("ARIL_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("ARIL_SQLITE_RETENTION", "3")

    # Re-import settings / reset DB connection so env takes effect.
    from app.core import config
    from app.core import db as store

    config.settings.aril_data_dir = str(tmp_path)
    config.settings.aril_sqlite_retention = 3
    # Use stub provider so chat tests don’t require a live OpenRouter key.
    config.settings.openrouter_api_key = ""
    store.reset_connection()
    yield tmp_path
    store.reset_connection()


@pytest.fixture()
def client(isolated_store: Path):
    from app.main import app

    return TestClient(app)


def test_sqlite_fifo_retention_on_judgements(client: TestClient, isolated_store: Path):
    for i in range(5):
        r = client.post(
            "/v1/feedback/prefer",
            json={
                "prompt": (
                    f"refactor python modules with unique token alpha{i}bravo "
                    f"and extra context word series{i}zeta for isolation"
                ),
                "model": "openai/gpt-4.1",
                "category": "coding",
            },
        )
        assert r.status_code == 200

    stats = client.get("/v1/store/stats").json()
    assert stats["retention"] == 3
    assert stats["counts"]["classifications"] == 3

    records = client.get("/v1/store/records").json()
    judgements = [row for row in records if row["kind"] == "judgement"]
    assert len(judgements) == 3
    snippets = " ".join(j["prompt_snippet"] for j in judgements)
    assert "alpha0bravo" not in snippets
    assert "alpha1bravo" not in snippets
    assert "alpha4bravo" in snippets

    assert (isolated_store / "aril.db").exists()


def test_store_delete_one_and_all(client: TestClient):
    r = client.post(
        "/v1/feedback/prefer",
        json={
            "prompt": "delete me please about coding tests",
            "model": "openai/gpt-4.1-mini",
            "category": "coding",
        },
    )
    assert r.status_code == 200
    cid = r.json()["classification_id"]

    listing = client.get("/v1/store/records").json()
    assert any(row["id"] == cid for row in listing)

    deleted = client.delete(f"/v1/store/records/{cid}")
    assert deleted.status_code == 200

    listing = client.get("/v1/store/records").json()
    assert all(row["id"] != cid for row in listing)

    client.post(
        "/v1/feedback/prefer",
        json={
            "prompt": "another judgement for bulk delete about coding",
            "model": "openai/gpt-4.1-mini",
            "category": "coding",
        },
    )
    wipe = client.delete("/v1/store/records")
    assert wipe.status_code == 200
    assert wipe.json()["ok"] is True
    assert client.get("/v1/store/records").json() == []


def test_store_retention_patch(client: TestClient):
    r = client.patch("/v1/store/retention", json={"retention": 10})
    assert r.status_code == 200
    body = r.json()
    assert body["retention"] == 10


def test_chat_transaction_dedupes_same_turn(isolated_store: Path):
    """Stream + fallback used to insert two chat_transaction rows for one send."""
    from app.core import analysis_cache as analysis_store
    from app.core import db as store

    store.reset_connection()
    prompt = "Unique dedupe token moon distance query omega"
    first = analysis_store.record_chat_transaction(
        session_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        prompt=prompt,
        model="openai/gpt-4.1-mini",
        category="cost",
        input_tokens=10,
        output_tokens=5,
        cost_usd=0.0001,
        cached=False,
    )
    # Second write may omit / change session_id (still same turn fingerprint).
    second = analysis_store.record_chat_transaction(
        session_id="ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb",
        prompt=prompt,
        model="openai/gpt-4.1-mini",
        category="cost",
        input_tokens=12,
        output_tokens=8,
        cost_usd=0.0002,
        cached=False,
    )
    assert first["id"] == second["id"]
    assert second.get("deduped") is True

    conn = store.connect()
    count = conn.execute(
        "SELECT COUNT(*) AS c FROM chat_transactions WHERE fingerprint = ?",
        (first["fingerprint"],),
    ).fetchone()["c"]
    assert count == 1


def test_chat_auto_judgement_on_first_send(client: TestClient):
    prompt = "Explain unique token autojudgementalpha how recycling works in swift"
    # No judgement yet
    preview0 = client.post(
        "/v1/preview",
        json={"prompt": prompt, "enhance_alternatives": False},
    ).json()
    assert preview0.get("user_override") is None

    first = client.post(
        "/v1/chat",
        json={
            "messages": [{"role": "user", "content": prompt}],
            "route_mode": "auto",
            "model": "openai/gpt-4.1-mini",
        },
    )
    assert first.status_code == 200

    preview1 = client.post(
        "/v1/preview",
        json={"prompt": prompt, "enhance_alternatives": False},
    ).json()
    assert preview1.get("user_override") is not None
    assert preview1["user_override"]["category_overridden"] is False

    judgements_before = [
        r for r in client.get("/v1/store/records").json() if r["kind"] == "judgement"
    ]
    count_before = len(judgements_before)

    # Second send must not create a second judgement for the same fingerprint
    second = client.post(
        "/v1/chat",
        json={
            "messages": [{"role": "user", "content": prompt}],
            "route_mode": "auto",
            "model": "openai/gpt-4.1-mini",
        },
    )
    assert second.status_code == 200
    judgements_after = [
        r for r in client.get("/v1/store/records").json() if r["kind"] == "judgement"
    ]
    assert len(judgements_after) == count_before


def test_chat_manual_does_not_write_judgement(client: TestClient):
    prompt = "Explain unique token manualnojjudgmentbeta edge cases in concurrency"
    before = client.post(
        "/v1/preview",
        json={"prompt": prompt, "enhance_alternatives": False},
    ).json()
    assert before.get("user_override") is None

    send = client.post(
        "/v1/chat",
        json={
            "messages": [{"role": "user", "content": prompt}],
            "route_mode": "manual",
            "model": "openai/gpt-4.1-mini",
        },
    )
    assert send.status_code == 200

    after = client.post(
        "/v1/preview",
        json={"prompt": prompt, "enhance_alternatives": False},
    ).json()
    assert after.get("user_override") is None


def test_chat_skip_auto_judgement_flag(client: TestClient):
    prompt = "Explain unique token skipautojudgementgamma early enter without analyse"
    before = client.post(
        "/v1/preview",
        json={"prompt": prompt, "enhance_alternatives": False},
    ).json()
    assert before.get("user_override") is None

    send = client.post(
        "/v1/chat",
        json={
            "messages": [{"role": "user", "content": prompt}],
            "route_mode": "auto",
            "model": "openai/gpt-4.1-mini",
            "skip_auto_judgement": True,
        },
    )
    assert send.status_code == 200

    after = client.post(
        "/v1/preview",
        json={"prompt": prompt, "enhance_alternatives": False},
    ).json()
    assert after.get("user_override") is None


def test_preview_manual_update_judgement_ignored(client: TestClient):
    prompt = "Debug unique token manualupdateomega lock contention in actors"
    prefer = client.post(
        "/v1/feedback/prefer",
        json={
            "prompt": prompt,
            "model": "openai/gpt-4.1-mini",
            "category": "coding",
        },
    )
    assert prefer.status_code == 200
    old_model = prefer.json()["model"]

    redo = client.post(
        "/v1/preview",
        json={
            "prompt": prompt,
            "enhance_alternatives": False,
            "skip_analysis_on_judgement": False,
            "update_judgement": True,
            "route_mode": "manual",
            "preferred_model": "openai/gpt-4.1",
            "routing_profile": {
                "coding": "anthropic/claude-sonnet-4",
                "security": "anthropic/claude-sonnet-4",
                "reasoning": "anthropic/claude-opus-4",
                "vision": "google/gemini-2.5-flash",
                "cost": "openai/gpt-4.1-mini",
                "performance": "google/gemini-2.5-flash",
                "confidence": "anthropic/claude-opus-4",
                "general": "meta-llama/llama-3.3-70b-instruct",
            },
        },
    )
    assert redo.status_code == 200
    body = redo.json()
    assert body.get("user_override") is not None
    assert body["user_override"]["model"] == old_model


def test_skip_analysis_on_judgement(client: TestClient):
    prompt = "Refactor unique token skipanalysiszeta modules with unit tests please"
    prefer = client.post(
        "/v1/feedback/prefer",
        json={
            "prompt": prompt,
            "model": "openai/gpt-4.1",
            "category": "coding",
            "category_overridden": True,
        },
    )
    assert prefer.status_code == 200

    full = client.post(
        "/v1/preview",
        json={
            "prompt": prompt,
            "enhance_alternatives": False,
            "skip_analysis_on_judgement": False,
        },
    )
    assert full.status_code == 200
    assert full.json().get("analysis_skipped") is False

    skipped = client.post(
        "/v1/preview",
        json={
            "prompt": prompt,
            "enhance_alternatives": True,
            "skip_analysis_on_judgement": True,
        },
    )
    assert skipped.status_code == 200
    body = skipped.json()
    assert body["analysis_skipped"] is True
    assert body["user_override"] is not None
    assert body["recommended_model"] == "openai/gpt-4.1"


def test_redo_analysis_updates_judgement(client: TestClient):
    prompt = "Debug unique token redoanalysisomega memory leak in swift concurrency"
    prefer = client.post(
        "/v1/feedback/prefer",
        json={
            "prompt": prompt,
            "model": "openai/gpt-4.1-mini",
            "category": "coding",
        },
    )
    assert prefer.status_code == 200
    old_id = prefer.json()["classification_id"]

    redo = client.post(
        "/v1/preview",
        json={
            "prompt": prompt,
            "enhance_alternatives": False,
            "skip_analysis_on_judgement": False,
            "update_judgement": True,
            "routing_profile": {
                "coding": "anthropic/claude-sonnet-4",
                "security": "anthropic/claude-sonnet-4",
                "reasoning": "anthropic/claude-opus-4",
                "vision": "google/gemini-2.5-flash",
                "cost": "openai/gpt-4.1-mini",
                "performance": "google/gemini-2.5-flash",
                "confidence": "anthropic/claude-opus-4",
                "general": "meta-llama/llama-3.3-70b-instruct",
            },
        },
    )
    assert redo.status_code == 200
    body = redo.json()
    assert body.get("analysis_skipped") is False
    assert body.get("user_override") is not None
    assert body["user_override"]["classification_id"] == old_id
    assert body["recommended_model"] == body["user_override"]["model"]
    # Fresh grade notes should not claim the analysis was skipped.
    assert not any("skipped" in note.lower() for note in body.get("grade", {}).get("notes", []))
