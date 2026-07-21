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

# Legacy blended fallbacks — live OpenRouter rates come from app.routing.pricing.
COST_PER_1K: dict[str, float] = {
    "openai/gpt-4.1": 0.005,
    "openai/gpt-4.1-mini": 0.001,
    "anthropic/claude-sonnet-4": 0.009,
    "anthropic/claude-opus-4": 0.045,
    "google/gemini-2.5-flash": 0.0014,
    "meta-llama/llama-3.3-70b-instruct": 0.0002,
}

# Suggested catalog per category — peers share the same capability (used by Judge).
CATEGORY_RECOMMENDATIONS: dict[RouteCategory, list[str]] = {
    RouteCategory.coding: [
        "openai/gpt-4.1",
        "anthropic/claude-sonnet-4",
        "google/gemini-2.5-flash",
    ],
    RouteCategory.security: [
        "anthropic/claude-sonnet-4",
        "anthropic/claude-opus-4",
        "openai/gpt-4.1",
    ],
    RouteCategory.reasoning: [
        "anthropic/claude-opus-4",
        "openai/gpt-4.1",
        "anthropic/claude-sonnet-4",
    ],
    RouteCategory.vision: [
        "google/gemini-2.5-flash",
        "openai/gpt-4.1",
        "anthropic/claude-sonnet-4",
    ],
    RouteCategory.cost: [
        "openai/gpt-4.1-mini",
        "meta-llama/llama-3.3-70b-instruct",
        "google/gemini-2.5-flash",
    ],
    RouteCategory.performance: [
        "google/gemini-2.5-flash",
        "openai/gpt-4.1-mini",
        "meta-llama/llama-3.3-70b-instruct",
    ],
    RouteCategory.confidence: [
        "anthropic/claude-opus-4",
        "anthropic/claude-sonnet-4",
        "openai/gpt-4.1",
    ],
    RouteCategory.general: [
        "meta-llama/llama-3.3-70b-instruct",
        "openai/gpt-4.1-mini",
        "openai/gpt-4.1",
    ],
}

# Image-generation capable peers when the prompt asks to create an image.
IMAGE_GEN_RECOMMENDATIONS: list[str] = [
    "google/gemini-2.5-flash-image",
    "google/gemini-2.5-flash",
    "openai/gpt-4.1",
]

CODING_HINTS = re.compile(
    r"\b(code|function|bug|refactor|typescript|python|swift|api|compile|unittest|pr|diff|implement|programming)\b",
    re.I,
)
SECURITY_HINTS = re.compile(
    r"\b(security|vuln|cve|owasp|auth|xss|injection|threat|pentest|encrypt|malware)\b",
    re.I,
)
REASONING_HINTS = re.compile(
    r"\b(reason|reasoning|think step|step by step|prove|proof|logic|math|analyse|analyze deeply|chain of thought|deduc|inference)\b",
    re.I,
)
VISION_HINTS = re.compile(
    r"\b(image|screenshot|photo|picture|diagram|chart|visual|ocr|describe what you see|looking at)\b",
    re.I,
)
ATTACHED_IMAGE_HINTS = re.compile(
    r"\[Attached:[^\]]*\.(png|jpe?g|gif|webp|heic|bmp|tiff?)[^\]]*\]",
    re.I,
)
# Text-to-image / generative intent (checked before generic vision)
IMAGE_GEN_HINTS = re.compile(
    r"("
    r"\b(generate|create|draw|paint|make|design|render|illustrate)\b.{0,40}\b(image|picture|illustration|photo|artwork|logo|icon|portrait|scene)\b"
    r"|"
    r"\b(image|picture|illustration|artwork|logo)\b.{0,20}\b(of|showing|depicting|with)\b"
    r"|"
    r"\b(text[\s-]?to[\s-]?image|dall[\s-]?e|stable diffusion|flux)\b"
    r")",
    re.I,
)

# OpenRouter chat model that can emit images when modalities=["image","text"]
IMAGE_GEN_MODEL = "google/gemini-2.5-flash-image"


def wants_image_generation(prompt: str) -> bool:
    return bool(IMAGE_GEN_HINTS.search(prompt or ""))


def estimate_tokens(text: str) -> int:
    return max(1, len(text) // 4)


def build_cache_insight(
    *,
    prompt: str,
    model: str,
    temperature: float,
    input_tokens: int,
) -> CacheInsight:
    """Cache eligibility, hit peek, and optional similar-hit prompt offer."""
    from app.core import cache as prompt_cache

    threshold = settings.aril_cache_token_threshold
    eligible = input_tokens > threshold
    tokens_to_eligible = 0 if eligible else max(0, threshold + 1 - input_tokens)
    would_hit = False
    savings: float | None = None
    suggested: str | None = None
    suggested_rationale: str | None = None

    key = prompt_cache.make_key(
        messages=[{"role": "user", "content": prompt}],
        model=model,
        temperature=temperature,
    )
    if eligible:
        would_hit = prompt_cache.peek(key) is not None
        savings = prompt_cache.savings_pct() if would_hit else 25.0

    if not would_hit:
        match = prompt_cache.suggest_hit(
            prompt=prompt,
            model=model,
            temperature=temperature,
        )
        if match and (match.get("prompt") or "").strip():
            suggested = str(match["prompt"]).strip()
            if suggested == prompt.strip():
                suggested = None
            else:
                suggested_rationale = (
                    "Close to a previously cached prompt — use it to hit the prompt cache "
                    f"(~{int(prompt_cache.savings_pct())}% savings)."
                )

    return CacheInsight(
        eligible=eligible,
        estimated_input_tokens=input_tokens,
        threshold=threshold,
        would_hit=would_hit,
        estimated_savings_pct=savings,
        tokens_to_eligible=tokens_to_eligible,
        suggested_hit_prompt=suggested,
        suggested_hit_rationale=suggested_rationale,
    )


def resolve_profile(profile: RoutingProfile | None) -> dict[RouteCategory, str]:
    base = dict(DEFAULT_PROFILE)
    if profile is not None:
        base.update(profile.as_map())
    return base


def classify(prompt: str) -> ClassificationResult:
    secondary: list[RouteCategory] = []
    if wants_image_generation(prompt):
        return ClassificationResult(
            primary=RouteCategory.vision,
            secondary=[RouteCategory.general],
            confidence=0.86,
        )
    if VISION_HINTS.search(prompt) or ATTACHED_IMAGE_HINTS.search(prompt):
        return ClassificationResult(
            primary=RouteCategory.vision,
            secondary=[RouteCategory.general],
            confidence=0.74,
        )
    if SECURITY_HINTS.search(prompt):
        return ClassificationResult(
            primary=RouteCategory.security,
            secondary=[RouteCategory.coding],
            confidence=0.72,
        )
    if REASONING_HINTS.search(prompt):
        return ClassificationResult(
            primary=RouteCategory.reasoning,
            secondary=[RouteCategory.confidence],
            confidence=0.7,
        )
    if CODING_HINTS.search(prompt):
        if len(prompt) > 2000:
            secondary.append(RouteCategory.confidence)
        return ClassificationResult(
            primary=RouteCategory.coding,
            secondary=secondary,
            confidence=0.68,
        )
    if len(prompt) < 80:
        return ClassificationResult(primary=RouteCategory.cost, confidence=0.55)
    return ClassificationResult(primary=RouteCategory.general, confidence=0.5)


def select_judge_models(
    prompt: str,
    category: RouteCategory,
    profile: dict[RouteCategory, str] | None = None,
    count: int = 3,
) -> list[str]:
    """Pick 1 profile model + up to 2 peers that share the same capability.

    Example: vision prompt → profile vision model + 2 other vision-capable models.
    """
    mapping = profile or DEFAULT_PROFILE
    picks: list[str] = []
    seen: set[str] = set()

    def add(model_id: str | None) -> None:
        mid = (model_id or "").strip()
        if not mid or mid in seen:
            return
        seen.add(mid)
        picks.append(mid)

    # Capability peer list for this classified need.
    if wants_image_generation(prompt):
        peers = list(IMAGE_GEN_RECOMMENDATIONS)
        add(IMAGE_GEN_MODEL)
    else:
        peers = list(CATEGORY_RECOMMENDATIONS.get(category, []))

    # Primary: user's routing-profile model for this capability.
    add(mapping.get(category))
    for mid in peers:
        add(mid)
        if len(picks) >= count:
            return picks[:count]

    # Fill from profile values if the peer catalog is thin.
    for mid in mapping.values():
        add(mid)
        if len(picks) >= count:
            break
    return picks[:count]


def grade_prompt(prompt: str) -> PromptGrade:
    """Score prompt quality (not model quality): clarity, constraints, success criteria, efficiency."""
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
    *,
    system_prompt: str | None = None,
) -> list[ModelEstimate]:
    from app.core.schemas import ScoreBreakdown

    mapping = profile or DEFAULT_PROFILE
    in_tok = estimate_tokens(prompt)
    sys = (system_prompt or "").strip()
    if sys:
        in_tok += estimate_tokens(sys)
    out_tok = min(2048, max(128, in_tok // 2))
    # Always score primary + cost/performance/confidence peers
    include = {primary, RouteCategory.cost, RouteCategory.performance, RouteCategory.confidence}
    if primary != RouteCategory.general:
        include.add(RouteCategory.general)

    from app.routing.pricing import estimate_cost_usd

    rows: list[ModelEstimate] = []
    for category, model_id in mapping.items():
        if category not in include:
            continue
        provider = model_id.split("/", 1)[0]
        cost = estimate_cost_usd(
            model_id,
            input_tokens=in_tok,
            output_tokens=out_tok,
        )
        fit_raw = 0.45 if category == primary else 0.12
        cost_raw = 1.0 - min(1.0, cost * 50)
        base_raw = 0.1
        from app.core.preferences import confidence_boost

        learn = confidence_boost(prompt, primary.value, model_id)
        # Weighted combine → confidence index (0..1)
        confidence_index = round(
            min(
                1.0,
                (fit_raw / 0.45) * 0.40  # normalized category fit weight
                + cost_raw * 0.25
                + (base_raw / 0.1) * 0.10
                + min(1.0, learn / 0.4) * 0.25,
            ),
            3,
        )
        score = round(fit_raw + 0.35 * cost_raw + base_raw + learn, 3)
        reasons: list[str] = []
        if category == primary:
            reasons.append(f"Best fit for classification '{primary.value}'.")
            reasons.append(f"Category preferred model → {model_id}.")
        if learn > 0:
            reasons.append(f"Learned preference boost +{learn:.2f}.")
        if "mini" in model_id or "flash" in model_id:
            reasons.append("Lower cost / faster path.")
        if "opus" in model_id:
            reasons.append("Higher reasoning / confidence prior.")
        reasons.append(
            f"Confidence index {confidence_index:.0%} "
            f"(fit {fit_raw:.2f}, cost {cost_raw:.2f}, base {base_raw:.2f}, learn {learn:.2f})."
        )
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
                breakdown=ScoreBreakdown(
                    category_fit=round(fit_raw / 0.45, 3),
                    cost=round(cost_raw, 3),
                    base=1.0,
                    learning=round(min(1.0, learn / 0.4), 3),
                    confidence_index=confidence_index,
                ),
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
    from app.core import preferences as pref_store
    from app.core.schemas import UserOverrideInsight

    classification = classify(req.prompt)
    user_override = None
    override = pref_store.lookup_classification(req.prompt)
    if override:
        try:
            override_cat = RouteCategory(override["category"])
            user_override = UserOverrideInsight(
                classification_id=override["id"],
                category=override_cat,
                model=override.get("model"),
                accuracy=override.get("accuracy"),
                category_overridden=bool(override.get("category_overridden")),
                prompt_snippet=override.get("prompt_snippet"),
            )
            if override.get("category_overridden"):
                classification = ClassificationResult(
                    primary=override_cat,
                    secondary=[c for c in classification.secondary if c != override_cat],
                    confidence=max(classification.confidence, 0.9),
                )
        except ValueError:
            user_override = None

    grade = grade_prompt(req.prompt)
    alts = alternatives if alternatives is not None else alternatives_for(req.prompt, grade)
    profile = resolve_profile(req.routing_profile)
    # Prefer live OpenRouter rates for prompt-cost analysis.
    from app.routing.pricing import ensure_pricing_cache

    ensure_pricing_cache()
    system_prompt = (req.system_prompt or "").strip() or None
    routes = score_routes(
        req.prompt,
        classification.primary,
        profile,
        system_prompt=system_prompt,
    )
    temp = req.temperature if req.temperature is not None else settings.aril_default_temperature

    # Prefer explicit profile mapping for the classified category (clearest Auto behavior)
    profile_pick = profile.get(classification.primary) or profile[RouteCategory.general]
    preference_reason: str | None = None

    if req.preferred_model and req.route_mode.value == "manual":
        recommended = req.preferred_model
    elif wants_image_generation(req.prompt):
        recommended = IMAGE_GEN_MODEL
    elif req.route_mode.value == "auto":
        pick = pref_store.preferred_model_for_prompt(
            req.prompt, classification.primary.value
        )
        if pick:
            recommended = pick["model"]
            preference_reason = pick.get("reason")
        elif user_override and user_override.model and user_override.category_overridden:
            recommended = user_override.model
        else:
            recommended = profile_pick
    elif user_override and user_override.model and user_override.category_overridden:
        recommended = user_override.model
    else:
        recommended = profile_pick

    # Ensure recommended appears first in routes for UI
    routes.sort(
        key=lambda r: (0 if r.model_id == recommended else 1, -r.score),
    )
    if preference_reason and routes:
        # Surface Prefer reason on the winning route for Routing analysis.
        top = routes[0]
        if top.model_id == recommended and preference_reason not in top.reasons:
            top.reasons = [preference_reason, *top.reasons]

    in_tok = estimate_tokens(req.prompt)
    if system_prompt:
        in_tok += estimate_tokens(system_prompt)
    cache = build_cache_insight(
        prompt=req.prompt,
        model=recommended,
        temperature=temp,
        input_tokens=in_tok,
    )

    src = alternatives_source
    if not alts:
        src = "none"

    return PreviewResponse(
        classification=classification,
        grade=grade,
        alternatives=alts,
        recommended_model=recommended,
        routes=routes,
        cache=cache,
        temperature=temp,
        route_mode=req.route_mode,
        alternatives_source=src,  # type: ignore[arg-type]
        user_override=user_override,
        analysis_skipped=False,
        preference_reason=preference_reason,
    )


def build_preview_from_judgement(
    req: PreviewRequest,
    override: dict,
    *,
    cached_payload: dict | None = None,
) -> PreviewResponse:
    """Reuse a Learning judgement without re-grading or calling the rewrite LLM.

    Optional analysis-cache payload supplies prior grade / alternatives.
    """
    from app.core.schemas import ScoreBreakdown, UserOverrideInsight
    from app.routing.pricing import ensure_pricing_cache, estimate_cost_usd

    try:
        primary = RouteCategory(override.get("category") or "general")
    except ValueError:
        primary = RouteCategory.general

    model = (override.get("model") or "").strip()
    profile = resolve_profile(req.routing_profile)
    if not model:
        model = profile.get(primary) or profile[RouteCategory.general]

    preference_reason: str | None = None
    if req.preferred_model and req.route_mode.value == "manual":
        recommended = req.preferred_model
    elif wants_image_generation(req.prompt):
        recommended = IMAGE_GEN_MODEL
    elif req.route_mode.value == "auto":
        from app.core import preferences as pref_store

        pick = pref_store.preferred_model_for_prompt(req.prompt, primary.value)
        if pick:
            recommended = pick["model"]
            preference_reason = pick.get("reason")
        else:
            recommended = model
    else:
        recommended = model

    confidence = 0.95 if override.get("category_overridden") else 0.85
    classification = ClassificationResult(
        primary=primary,
        secondary=[],
        confidence=confidence,
    )
    user_override = UserOverrideInsight(
        classification_id=str(override.get("id") or ""),
        category=primary,
        model=override.get("model"),
        accuracy=override.get("accuracy"),
        category_overridden=bool(override.get("category_overridden")),
        prompt_snippet=override.get("prompt_snippet"),
    )

    payload = cached_payload or {}
    alts: list[PromptAlternative] = []
    for raw in payload.get("alternatives") or []:
        if isinstance(raw, dict):
            try:
                alts.append(PromptAlternative(**raw))
            except Exception:
                continue

    grade_raw = payload.get("grade")
    if isinstance(grade_raw, dict):
        try:
            grade = PromptGrade(**grade_raw)
            grade = grade.model_copy(
                update={
                    "notes": list(grade.notes)
                    + ["Analysis skipped — reused Learning judgement (token saver)."]
                }
            )
        except Exception:
            grade = _judgement_stub_grade(override)
    else:
        grade = _judgement_stub_grade(override)

    temp = req.temperature if req.temperature is not None else settings.aril_default_temperature
    system_prompt = (req.system_prompt or "").strip() or None
    in_tok = estimate_tokens(req.prompt)
    if system_prompt:
        in_tok += estimate_tokens(system_prompt)
    out_tok = max(120, min(800, in_tok // 2))

    ensure_pricing_cache()
    cost = estimate_cost_usd(
        recommended,
        input_tokens=in_tok,
        output_tokens=out_tok,
        web_search=False,
    )
    learn_note = (
        "Reused Learning judgement — prompt analysis skipped to save tokens."
    )
    route_reasons = [learn_note]
    if preference_reason:
        route_reasons = [preference_reason, learn_note]
    routes = [
        ModelEstimate(
            model_id=recommended,
            provider=recommended.split("/", 1)[0],
            category_fit=primary,
            estimated_input_tokens=in_tok,
            estimated_output_tokens=out_tok,
            estimated_cost_usd=cost,
            score=1.0,
            reasons=route_reasons,
            breakdown=ScoreBreakdown(
                category_fit=1.0,
                cost=1.0,
                base=1.0,
                learning=1.0,
                confidence_index=confidence,
            ),
        )
    ]

    cache = build_cache_insight(
        prompt=req.prompt,
        model=recommended,
        temperature=temp,
        input_tokens=in_tok,
    )

    src = "judgement"
    if alts and payload:
        src = "cache"
    elif not alts:
        src = "none"

    return PreviewResponse(
        classification=classification,
        grade=grade,
        alternatives=alts,
        recommended_model=recommended,
        routes=routes,
        cache=cache,
        temperature=temp,
        route_mode=req.route_mode,
        alternatives_source=src,  # type: ignore[arg-type]
        user_override=user_override,
        analysis_skipped=True,
        preference_reason=preference_reason,
    )


def _judgement_stub_grade(override: dict) -> PromptGrade:
    acc = override.get("accuracy")
    overall = float(acc) if acc is not None else 0.8
    overall = min(1.0, max(0.0, overall))
    return PromptGrade(
        overall=overall,
        clarity=overall,
        constraints=overall,
        success_criteria=overall,
        token_efficiency=0.9,
        notes=[
            "Analysis skipped — reused Learning judgement (token saver).",
            "Use Redo Analysis on the intelligence panel for a fresh grade.",
        ],
    )
