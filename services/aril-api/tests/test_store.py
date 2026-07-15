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


def test_chat_writes_transaction(client: TestClient):
    r = client.post(
        "/v1/chat",
        json={
            "messages": [{"role": "user", "content": "Hello SQLite store path"}],
            "route_mode": "auto",
            "model": "openai/gpt-4.1-mini",
        },
    )
    assert r.status_code == 200
    records = client.get("/v1/store/records").json()
    assert any(row["kind"] == "chat_transaction" for row in records)


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
