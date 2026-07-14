"""LLM-assisted prompt rewrites via OpenRouter (cheap model)."""

from __future__ import annotations

import json
import re

from app.core.config import settings
from app.core.schemas import PromptAlternative, PromptGrade
from app.providers.base import ProviderMessage, get_chat_provider
from app.routing.pipeline import alternatives_for


REWRITE_SYSTEM = """You improve user prompts for LLM quality.
Return ONLY valid JSON:
{"alternatives":[{"id":"alt-1","text":"...","rationale":"...","estimated_grade":0.0}]}
Rules:
- Provide 1 or 2 improved prompts
- Keep the user's intent
- Add constraints/acceptance criteria when missing
- estimated_grade is 0..1
- No markdown fences"""


async def llm_alternatives(prompt: str, grade: PromptGrade) -> list[PromptAlternative]:
    """Prefer LLM rewrites; fall back to heuristics."""
    heuristic = alternatives_for(prompt, grade)
    if grade.overall >= 0.78:
        return []
    if not settings.openrouter_api_key.strip():
        return heuristic

    provider = get_chat_provider()
    model = settings.aril_rewrite_model
    user = (
        f"Current grade overall={grade.overall:.2f}, notes={grade.notes}\n\n"
        f"Prompt:\n{prompt}"
    )
    try:
        result = await provider.complete(
            [
                ProviderMessage(role="system", content=REWRITE_SYSTEM),
                ProviderMessage(role="user", content=user),
            ],
            model=model,
            temperature=0.3,
        )
        parsed = _parse_json(result.content)
        alts = parsed.get("alternatives") if isinstance(parsed, dict) else None
        if not isinstance(alts, list) or not alts:
            return heuristic
        out: list[PromptAlternative] = []
        for i, row in enumerate(alts[:2]):
            if not isinstance(row, dict):
                continue
            text = str(row.get("text") or "").strip()
            if not text:
                continue
            out.append(
                PromptAlternative(
                    id=f"llm-alt-{i+1}",
                    text=text,
                    rationale=str(row.get("rationale") or "LLM-improved prompt."),
                    estimated_grade=min(1.0, max(0.0, float(row.get("estimated_grade") or grade.overall + 0.15))),
                )
            )
        return out or heuristic
    except Exception:
        return heuristic


def _parse_json(text: str) -> dict:
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", text)
        if match:
            return json.loads(match.group(0))
        raise
