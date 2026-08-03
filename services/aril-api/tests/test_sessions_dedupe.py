"""Session store dedupe / cost-footer survival across record+upsert races."""

from __future__ import annotations

from pathlib import Path

import pytest

from app.core import sessions as session_store
from app.core.schemas import ChatMessage, SessionUpsert


@pytest.fixture()
def isolated_sessions(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("ARIL_DATA_DIR", str(tmp_path))
    from app.core import config

    config.settings.aril_data_dir = str(tmp_path)
    # Reset module-level store between tests.
    session_store._SESSIONS.clear()
    session_store._TOMBSTONES.clear()
    session_store._LOADED = False
    yield tmp_path
    session_store._SESSIONS.clear()
    session_store._TOMBSTONES.clear()
    session_store._LOADED = False


def test_with_cost_footer_round_trip(isolated_sessions: Path):
    text = session_store.with_cost_footer(
        "Rancher manages Kubernetes.",
        model="openai/gpt-4.1-mini",
        cost_usd=0.0116,
        input_tokens=3495,
        output_tokens=148,
    )
    assert "gpt-4.1-mini" in text
    assert "tokens used 3495 / 148" in text
    assert "$0.0116" in text
    assert session_store._norm_content(text) == "Rancher manages Kubernetes."
    assert session_store._has_cost_footer(text)


def test_dedupe_collapses_same_user_near_duplicate_assistants(isolated_sessions: Path):
    msgs = [
        {"role": "user", "content": "what is rancher"},
        {"role": "assistant", "content": "Rancher is a Kubernetes platform.\n\n[ gpt-4.1-mini · tokens used 100 / 50: cost = $0.0100 ]"},
        {"role": "user", "content": "what is rancher"},
        {"role": "assistant", "content": "Rancher is an open-source Kubernetes management platform."},
    ]
    out = session_store._dedupe_messages(msgs)
    assert len(out) == 2
    assert out[0]["role"] == "user"
    assert out[1]["role"] == "assistant"
    assert session_store._has_cost_footer(out[1]["content"])


def test_record_chat_turn_merges_same_user_instead_of_duplicating(isolated_sessions: Path):
    sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    session_store.record_chat_turn(
        sid,
        title="what is rancher",
        user_content="what is rancher",
        assistant_content="Answer A about Rancher.",
    )
    session_store.record_chat_turn(
        sid,
        title="what is rancher",
        user_content="what is rancher",
        assistant_content=session_store.with_cost_footer(
            "Answer B about Rancher with more detail.",
            model="gpt-4.1-mini",
            cost_usd=0.01,
            input_tokens=10,
            output_tokens=20,
        ),
    )
    detail = session_store.get_session(sid)
    assert detail is not None
    assert len(detail.messages) == 2
    assert session_store._has_cost_footer(detail.messages[1].content)


def test_upsert_keeps_footer_over_bare_gateway_copy(isolated_sessions: Path):
    sid = "11111111-2222-3333-4444-555555555555"
    session_store.record_chat_turn(
        sid,
        title="what is rancher",
        user_content="what is rancher",
        assistant_content="Rancher manages clusters.",
    )
    footered = session_store.with_cost_footer(
        "Rancher manages clusters.",
        model="gpt-4.1-mini",
        cost_usd=0.0056,
        input_tokens=40,
        output_tokens=12,
    )
    session_store.upsert_session(
        SessionUpsert(
            id=sid,
            title="what is rancher",
            messages=[
                ChatMessage(role="user", content="what is rancher"),
                ChatMessage(role="assistant", content=footered),
            ],
        )
    )
    detail = session_store.get_session(sid)
    assert detail is not None
    assert len(detail.messages) == 2
    assert session_store._has_cost_footer(detail.messages[1].content)
