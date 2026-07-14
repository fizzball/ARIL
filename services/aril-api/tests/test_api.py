from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["gateway"] == "ready"
    assert "chat_provider" in body


def test_preview_coding():
    r = client.post(
        "/v1/preview",
        json={
            "prompt": "Refactor this Python function and add unit tests for edge cases.",
            "enhance_alternatives": False,
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["classification"]["primary"] == "coding"
    assert body["recommended_model"]
    assert len(body["routes"]) >= 1
    assert "overall" in body["grade"]


def test_preview_with_routing_profile():
    r = client.post(
        "/v1/preview",
        json={
            "prompt": "Write a secure auth middleware in Swift",
            "enhance_alternatives": False,
            "routing_profile": {
                "coding": "google/gemini-2.5-flash",
                "security": "anthropic/claude-sonnet-4",
                "cost": "openai/gpt-4.1-mini",
                "performance": "openai/gpt-4.1-mini",
                "confidence": "anthropic/claude-opus-4",
                "general": "openai/gpt-4.1",
            },
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["classification"]["primary"] in ("coding", "security")
    model_ids = {row["model_id"] for row in body["routes"]}
    assert "google/gemini-2.5-flash" in model_ids or "anthropic/claude-sonnet-4" in model_ids


def test_compare_endpoint():
    r = client.post(
        "/v1/compare",
        json={
            "messages": [{"role": "user", "content": "Reply with the word COMPARE_OK only."}],
            "models": ["openai/gpt-4.1-mini"],
            "temperature": 0,
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert len(body["results"]) >= 1
    assert body["session_id"]


def test_prompt_cache_module():
    from app.core import cache as prompt_cache

    key = prompt_cache.make_key(
        messages=[{"role": "user", "content": "hello cache"}],
        model="openai/gpt-4.1-mini",
        temperature=0.0,
    )
    prompt_cache.put(
        key,
        {
            "content": "cached-content",
            "model": "openai/gpt-4.1-mini",
            "input_tokens": 2000,
            "output_tokens": 10,
            "cost_usd": 0.01,
        },
    )
    hit = prompt_cache.peek(key)
    assert hit is not None
    assert hit["content"] == "cached-content"
    assert prompt_cache.eligible(2000) is True
    assert prompt_cache.eligible(10) is False


def test_chat_stub_or_live():
    r = client.post(
        "/v1/chat",
        json={
            "messages": [{"role": "user", "content": "Hello ARIL"}],
            "route_mode": "auto",
            "model": "openai/gpt-4.1-mini",
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["message"]["role"] == "assistant"
    assert body["session_id"]
    assert len(body["message"]["content"]) > 0


def test_chat_stream_sse():
    with client.stream(
        "POST",
        "/v1/chat/stream",
        json={
            "messages": [{"role": "user", "content": "Say hi"}],
            "model": "openai/gpt-4.1-mini",
        },
    ) as r:
        assert r.status_code == 200
        text = "".join(r.iter_text())
    assert "event: token" in text or "event: done" in text or "event: error" in text


def test_sessions_roundtrip():
    put = client.put(
        "/v1/sessions",
        json={
            "title": "Test session",
            "messages": [
                {"role": "user", "content": "Hello"},
                {"role": "assistant", "content": "Hi"},
            ],
        },
    )
    assert put.status_code == 200
    sid = put.json()["id"]
    listed = client.get("/v1/sessions")
    assert listed.status_code == 200
    assert any(s["id"] == sid for s in listed.json())
    got = client.get(f"/v1/sessions/{sid}")
    assert got.status_code == 200
    assert len(got.json()["messages"]) == 2
    deleted = client.delete(f"/v1/sessions/{sid}")
    assert deleted.status_code == 200


def test_models_list():
    r = client.get("/v1/models")
    assert r.status_code == 200
    assert len(r.json()["models"]) >= 3
