"""Weekly OpenRouter popularity rankings helpers."""

from __future__ import annotations

from app.core.schemas import OpenRouterWeeklyRankingsResponse
from app.routing import pricing


def test_list_weekly_rankings_empty_when_unreachable(monkeypatch):
    monkeypatch.setattr(pricing, "_WEEKLY_RANKINGS", [])
    monkeypatch.setattr(pricing, "_WEEKLY_RANKINGS_AT", 0.0)

    class Boom:
        def __init__(self, *args, **kwargs):
            raise RuntimeError("offline")

    monkeypatch.setattr(pricing.httpx, "Client", Boom)
    rows = pricing.list_weekly_rankings(limit=10, force_refresh=True)
    assert rows == []


def test_weekly_rankings_schema_accepts_rows():
    body = OpenRouterWeeklyRankingsResponse.model_validate(
        {
            "models": [
                {
                    "rank": 1,
                    "id": "openai/gpt-4.1-mini",
                    "name": "GPT-4.1 Mini",
                    "prompt_per_1k": 0.0004,
                    "completion_per_1k": 0.0016,
                }
            ],
            "count": 1,
            "period": "top-weekly",
            "refreshed": True,
            "source": "openrouter",
        }
    )
    assert body.models[0].id == "openai/gpt-4.1-mini"
    assert body.models[0].rank == 1
