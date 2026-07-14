from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["gateway"] == "ready"


def test_preview_coding():
    r = client.post(
        "/v1/preview",
        json={"prompt": "Refactor this Python function and add unit tests for edge cases."},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["classification"]["primary"] == "coding"
    assert body["recommended_model"]
    assert len(body["routes"]) >= 1
    assert "overall" in body["grade"]


def test_chat_stub():
    r = client.post(
        "/v1/chat",
        json={
            "messages": [{"role": "user", "content": "Hello ARIL"}],
            "route_mode": "auto",
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["message"]["role"] == "assistant"
    assert "ARIL stub" in body["message"]["content"]


def test_models_list():
    r = client.get("/v1/models")
    assert r.status_code == 200
    assert len(r.json()["models"]) >= 3
