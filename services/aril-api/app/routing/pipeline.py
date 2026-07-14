"""Heuristic classifier / grader / router."""

from __future__ import annotations

import re

from app.core.config import settings
from app.core.schemas import (
    CacheInsight,
    ClassificationResult,
    ModelEstimate,
    PreviewRequest,
    PreviewResponse,
    PromptAlternative,
    PromptGrade,
    RouteCategory,
    RoutingProfile,
)

DEFAULT_PROFILE = RoutingProfile().as_map()

COST_PER_1K: dict[str, float] = {
    "openai/gpt-4.1": 0.01,
    "openai/gpt-4.1-mini": 0.002,
    "anthropic/claude-sonnet-4": 0.012,
    "anthropic/claude-opus-4": 0.04,
    "google/gemini-2.5-flash": 0.0015,
    "meta-llama/llama-3.3-70b-instruct": 0.0008,
}

CODING_HINTS = re.compile(
    r"\b(code|function|bug|refactor|typescript|python|swift|api|compile|unittest|pr|diff)\b",
    re.I,
)
SECURITY_HINTS = re.compile(
    r"\b(security|vuln|cve|owasp|auth|xss|injection|threat|pentest|encrypt)\b",
    re.I,
)


def estimate_tokens(text: str) -> int:
    return max(1, len(text) // 4)


def resolve_profile(profile: RoutingProfile | None) -> dict[RouteCategory, str]:
    base = dict(DEFAULT_PROFILE)
    if profile is not None:
        base.update(profile.as_map())
    return base


def classify(prompt: str) -> ClassificationResult:
    secondary: list[RouteCategory] = []
    if SECURITY_HINTS.search(prompt):
        return ClassificationResult(primary=RouteCategory.security, secondary=[RouteCategory.coding], confidence=0.72)
    if CODING_HINTS.search(prompt):
        if len(prompt) > 2000:
            secondary.append(RouteCategory.confidence)
        return ClassificationResult(primary=RouteCategory.coding, secondary=secondary, confidence=0.68)
    if len(prompt) < 80:
        return ClassificationResult(primary=RouteCategory.cost, confidence=0.55)
    return ClassificationResult(primary=RouteCategory.general, confidence=0.5)


def grade_prompt(prompt: str) -> PromptGrade:
    length = len(prompt.strip())
    has_question = "?" in prompt
    has_bullets = bool(re.search(r"(^|\n)\s*[-*•\d]", prompt))
    has_criteria = bool(re.search(r"\b(must|should|acceptance|constraint|require)\b", prompt, re.I))

    clarity = 0.4 + (0.2 if length > 40 else 0) + (0.2 if has_question or has_bullets else 0)
    constraints = 0.35 + (0.4 if has_criteria else 0) + (0.1 if has_bullets else 0)
    success = 0.3 + (0.35 if has_criteria else 0) + (0.15 if "example" in prompt.lower() else 0)
    efficiency = 0.8 if length < 2000 else (0.55 if length < 6000 else 0.35)
    clarity = min(1.0, clarity)
    constraints = min(1.0, constraints)
    success = min(1.0, success)
    overall = round((clarity + constraints + success + efficiency) / 4, 3)

    notes: list[str] = []
    if not has_criteria:
        notes.append("Add explicit constraints or acceptance criteria.")
    if length < 40:
        notes.append("Prompt is very short — add context for higher confidence.")
    if length > 4000:
        notes.append("Long prompt — consider structure and cache (>1024 tokens).")

    return PromptGrade(
        overall=overall,
        clarity=round(clarity, 3),
        constraints=round(constraints, 3),
        success_criteria=round(success, 3),
        token_efficiency=round(efficiency, 3),
        notes=notes,
    )


def alternatives_for(prompt: str, grade: PromptGrade) -> list[PromptAlternative]:
    if grade.overall >= 0.75:
        return []
    tightened = prompt.strip()
    if not tightened.endswith((".", "?", "!")):
        tightened += "."
    alt1 = (
        f"{tightened}\n\nConstraints:\n"
        "- Be precise and actionable.\n"
        "- State assumptions explicitly.\n"
        "- Provide acceptance criteria for a correct answer."
    )
    alt2 = (
        f"Task: {prompt.strip()}\n\n"
        "Please respond with:\n"
        "1) Brief plan\n2) Solution\n3) Risks / edge cases"
    )
    return [
        PromptAlternative(
            id="alt-constraints",
            text=alt1,
            rationale="Adds constraints and acceptance criteria to raise grade.",
            estimated_grade=min(1.0, grade.overall + 0.18),
        ),
        PromptAlternative(
            id="alt-structured",
            text=alt2,
            rationale="Structures the ask for more reliable model output.",
            estimated_grade=min(1.0, grade.overall + 0.12),
        ),
    ]


def score_routes(
    prompt: str,
    primary: RouteCategory,
    profile: dict[RouteCategory, str] | None = None,
) -> list[ModelEstimate]:
    mapping = profile or DEFAULT_PROFILE
    in_tok = estimate_tokens(prompt)
    out_tok = min(2048, max(128, in_tok // 2))
    rows: list[ModelEstimate] = []
    for category, model_id in mapping.items():
        if category == RouteCategory.general and primary != RouteCategory.general:
            continue
        provider = model_id.split("/", 1)[0]
        rate = COST_PER_1K.get(model_id, 0.01)
        cost = round((in_tok + out_tok) / 1000 * rate, 6)
        fit_bonus = 0.35 if category == primary else 0.1
        cost_score = 1.0 - min(1.0, cost * 50)
        from app.core.preferences import confidence_boost

        learn = confidence_boost(prompt, primary.value, model_id)
        score = round(fit_bonus + 0.4 * cost_score + 0.15 + learn, 3)
        reasons = []
        if category == primary:
            reasons.append(f"Best fit for classification '{primary.value}'.")
            reasons.append(f"Mapped from Settings profile → {model_id}.")
        if learn > 0:
            reasons.append(f"Learned preference boost +{learn:.2f}.")
        if "mini" in model_id or "flash" in model_id:
            reasons.append("Lower cost / faster path.")
        if "opus" in model_id or "claude-sonnet" in model_id:
            reasons.append("Higher capability prior.")
        rows.append(
            ModelEstimate(
                model_id=model_id,
                provider=provider,
                category_fit=category,
                estimated_input_tokens=in_tok,
                estimated_output_tokens=out_tok,
                estimated_cost_usd=cost,
                score=score,
                reasons=reasons,
            )
        )
    rows.sort(key=lambda r: r.score, reverse=True)
    return rows


def build_preview(
    req: PreviewRequest,
    *,
    alternatives: list[PromptAlternative] | None = None,
    alternatives_source: str = "heuristic",
) -> PreviewResponse:
    classification = classify(req.prompt)
    grade = grade_prompt(req.prompt)
    alts = alternatives if alternatives is not None else alternatives_for(req.prompt, grade)
    profile = resolve_profile(req.routing_profile)
    routes = score_routes(req.prompt, classification.primary, profile)
    temp = req.temperature if req.temperature is not None else settings.aril_default_temperature

    if req.preferred_model and req.route_mode.value == "manual":
        recommended = req.preferred_model
    else:
        recommended = routes[0].model_id if routes else profile[classification.primary]

    in_tok = estimate_tokens(req.prompt)
    eligible = in_tok > settings.aril_cache_token_threshold
    would_hit = False
    savings = None
    if eligible:
        from app.core import cache as prompt_cache

        key = prompt_cache.make_key(
            messages=[{"role": "user", "content": req.prompt}],
            model=recommended,
            temperature=temp,
        )
        would_hit = prompt_cache.peek(key) is not None
        savings = prompt_cache.savings_pct() if would_hit else 25.0

    src = alternatives_source
    if not alts:
        src = "none"

    return PreviewResponse(
        classification=classification,
        grade=grade,
        alternatives=alts,
        recommended_model=recommended,
        routes=routes,
        cache=CacheInsight(
            eligible=eligible,
            estimated_input_tokens=in_tok,
            threshold=settings.aril_cache_token_threshold,
            would_hit=would_hit,
            estimated_savings_pct=savings,
        ),
        temperature=temp,
        route_mode=req.route_mode,
        alternatives_source=src,  # type: ignore[arg-type]
    )
