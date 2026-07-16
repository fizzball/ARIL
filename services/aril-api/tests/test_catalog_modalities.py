"""Catalog modality extraction and preferences snapshot win maps."""

from __future__ import annotations

from pathlib import Path

import pytest

from app.core import config
from app.core import db as store
from app.core import preferences as pref
from app.core.schemas import OpenRouterCatalogModel, PreferencesSnapshot
from app.routing.pricing import modalities_from_catalog_row


@pytest.fixture()
def isolated_prefs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("ARIL_DATA_DIR", str(tmp_path))
    config.settings.aril_data_dir = str(tmp_path)
    store.reset_connection()
    yield tmp_path
    store.reset_connection()


def test_modalities_from_architecture_lists():
    inputs, outputs = modalities_from_catalog_row(
        {
            "id": "google/gemini-2.5-flash",
            "architecture": {
                "input_modalities": ["text", "image"],
                "output_modalities": ["text"],
            },
        }
    )
    assert inputs == ["text", "image"]
    assert outputs == ["text"]


def test_modalities_from_legacy_modality_string():
    inputs, outputs = modalities_from_catalog_row(
        {
            "architecture": {"modality": "text+image->text"},
        }
    )
    assert inputs == ["text", "image"]
    assert outputs == ["text"]


def test_modalities_image_gen_output():
    inputs, outputs = modalities_from_catalog_row(
        {
            "architecture": {
                "input_modalities": ["text"],
                "output_modalities": ["image", "text"],
            },
        }
    )
    assert "image" in outputs
    assert inputs == ["text"]


def test_modalities_missing_returns_empty():
    assert modalities_from_catalog_row({"id": "x"}) == ([], [])


def test_openrouter_catalog_model_schema_accepts_modalities():
    row = OpenRouterCatalogModel(
        id="google/gemini-2.5-flash",
        name="Gemini",
        prompt_per_1k=0.0003,
        completion_per_1k=0.0025,
        input_modalities=["text", "image"],
        output_modalities=["text"],
    )
    dumped = row.model_dump()
    assert dumped["input_modalities"] == ["text", "image"]
    assert dumped["output_modalities"] == ["text"]


def test_preferences_snapshot_includes_category_wins(isolated_prefs: Path):
    pref.record_preference(
        prompt="unique prefer snapshot coding alpha about refactoring",
        category="coding",
        model="openai/gpt-4.1",
        accuracy=0.9,
    )
    snap = pref.snapshot()
    assert "coding" in snap["category_wins"]
    assert snap["category_wins"]["coding"]["openai/gpt-4.1"] >= 1
    parsed = PreferencesSnapshot.model_validate(snap)
    assert parsed.category_wins["coding"]["openai/gpt-4.1"] >= 1
    assert parsed.classifications
