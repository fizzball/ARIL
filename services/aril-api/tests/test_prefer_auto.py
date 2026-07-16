"""Tests for Prefer → Auto model promotion."""

from __future__ import annotations

from pathlib import Path

import pytest

from app.core import config
from app.core import db as store
from app.core import preferences as pref


@pytest.fixture()
def isolated_prefs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("ARIL_DATA_DIR", str(tmp_path))
    config.settings.aril_data_dir = str(tmp_path)
    store.reset_connection()
    yield tmp_path
    store.reset_connection()


def test_auto_seed_does_not_count_wins(isolated_prefs: Path):
    prompt = "unique fingerprint seednowinsalpha coding task about refactoring modules"
    created = pref.ensure_auto_judgement(
        prompt=prompt,
        category="coding",
        model="openai/gpt-4.1-mini",
    )
    assert created is not None
    assert pref.preferred_model_for_prompt(prompt, "coding") is None
    snap = pref.snapshot()
    assert snap["category_wins"] == {}
    assert snap["fingerprint_wins"] == {}


def test_fingerprint_prefer_beats_category(isolated_prefs: Path):
    prompt = "unique fingerprint preferbeats categorybeta explain async rust lifetimes"
    pref.record_preference(
        prompt=prompt,
        category="coding",
        model="anthropic/claude-sonnet-4",
        accuracy=0.9,
    )
    # Different prompts, same category — category win for another model
    pref.record_preference(
        prompt="totally different coding prompt about javascript promises zeta",
        category="coding",
        model="openai/gpt-4.1",
        accuracy=0.8,
    )
    pref.record_preference(
        prompt="another coding ask about typescript generics omega",
        category="coding",
        model="openai/gpt-4.1",
        accuracy=0.85,
    )

    pick = pref.preferred_model_for_prompt(prompt, "coding")
    assert pick is not None
    assert pick["model"] == "anthropic/claude-sonnet-4"
    assert pick["source"] == "fingerprint"
    assert "similar prompt" in pick["reason"]
    assert "Coding" in pick["reason"]


def test_category_prefer_when_no_fingerprint(isolated_prefs: Path):
    pref.record_preference(
        prompt="security review of oauth flows and jwt rotation uniqueone",
        category="security",
        model="anthropic/claude-sonnet-4",
        accuracy=0.95,
    )
    pick = pref.preferred_model_for_prompt(
        "brand new security prompt about threat modeling uniquesec",
        "security",
    )
    assert pick is not None
    assert pick["model"] == "anthropic/claude-sonnet-4"
    assert pick["source"] == "category"
    assert "Because you preferred anthropic/claude-sonnet-4 for Security" in pick["reason"]


def test_category_tie_does_not_promote(isolated_prefs: Path):
    pref.record_preference(
        prompt="cost optimize query one uniquetiea",
        category="cost",
        model="openai/gpt-4.1-mini",
        accuracy=0.7,
    )
    pref.record_preference(
        prompt="cost optimize query two uniquetieb",
        category="cost",
        model="google/gemini-2.5-flash",
        accuracy=0.7,
    )
    pick = pref.preferred_model_for_prompt("fresh cost prompt uniquetiec", "cost")
    assert pick is None


def test_auto_ignores_stale_manual_req_model(isolated_prefs: Path):
    """Auto must use profile mapping, not a leftover Manual `model` field."""
    from app.api.routes import _resolve_model
    from app.core.schemas import RouteMode
    from app.routing.pipeline import DEFAULT_PROFILE

    prompt = "everyday writing tip about clear emails uniquestaleautoignore"
    model, classification, reason = _resolve_model(
        "anthropic/claude-sonnet-4",  # stale Manual lock
        prompt,
        None,
        route_mode=RouteMode.auto,
    )
    assert reason is None
    assert model == DEFAULT_PROFILE[classification.primary]
    assert model != "anthropic/claude-sonnet-4"


def test_manual_honors_req_model(isolated_prefs: Path):
    from app.api.routes import _resolve_model
    from app.core.schemas import RouteMode

    model, _, reason = _resolve_model(
        "anthropic/claude-sonnet-4",
        "everyday writing tip about clear emails uniquemanualhonor",
        None,
        route_mode=RouteMode.manual,
    )
    assert model == "anthropic/claude-sonnet-4"
    assert reason is None


def test_preview_includes_preference_reason(isolated_prefs: Path):
    from fastapi.testclient import TestClient

    from app.main import app

    prompt = "coding help with unique previewreasonprompt alpha please"
    pref.record_preference(
        prompt=prompt,
        category="coding",
        model="anthropic/claude-sonnet-4",
        accuracy=0.9,
    )
    client = TestClient(app)
    resp = client.post(
        "/v1/preview",
        json={
            "prompt": prompt,
            "route_mode": "auto",
            "enhance_alternatives": False,
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["recommended_model"] == "anthropic/claude-sonnet-4"
    assert body.get("preference_reason")
    assert "preferred" in body["preference_reason"].lower()
