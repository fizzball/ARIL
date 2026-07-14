from __future__ import annotations

import uuid

from fastapi import APIRouter, HTTPException

from app.core.config import settings
from app.core.schemas import (
    ChatRequest,
    ChatResponse,
    ChatMessage,
    PreviewRequest,
    PreviewResponse,
    RouteCategory,
)
from app.providers.base import ProviderMessage, get_chat_provider
from app.routing.pipeline import DEFAULT_PROFILE, build_preview, classify, estimate_tokens

router = APIRouter(prefix="/v1")


@router.post("/preview", response_model=PreviewResponse)
async def preview(req: PreviewRequest) -> PreviewResponse:
    """Classify, grade, suggest alternatives, and rank routes — no provider call."""
    return build_preview(req)


@router.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    """Execute a chat turn via OpenRouter (or stub if no key)."""
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    classification = classify(last_user)
    model = req.model or DEFAULT_PROFILE[classification.primary]

    temperature = (
        req.temperature if req.temperature is not None else settings.aril_default_temperature
    )
    provider = get_chat_provider()
    try:
        result = await provider.complete(
            [ProviderMessage(role=m.role, content=m.content) for m in req.messages],
            model=model,
            temperature=temperature,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    in_tok = result.input_tokens
    cached = bool(req.use_cache and in_tok > settings.aril_cache_token_threshold)

    return ChatResponse(
        session_id=req.session_id or str(uuid.uuid4()),
        message=ChatMessage(role="assistant", content=result.content),
        model=result.model,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        cost_usd=result.cost_usd * (0.55 if cached else 1.0),
        cached=cached,
        route_category=classification.primary,
    )


@router.get("/models")
async def list_models() -> dict:
    """Models addressed via OpenRouter IDs (provider/model)."""
    return {
        "gateway": "openrouter" if settings.openrouter_api_key.strip() else "stub",
        "models": [
            {
                "id": "openai/gpt-4.1",
                "provider": "openrouter",
                "upstream": "openai",
                "categories": ["coding", "general"],
            },
            {
                "id": "openai/gpt-4.1-mini",
                "provider": "openrouter",
                "upstream": "openai",
                "categories": ["cost", "performance"],
            },
            {
                "id": "anthropic/claude-sonnet-4",
                "provider": "openrouter",
                "upstream": "anthropic",
                "categories": ["security"],
            },
            {
                "id": "anthropic/claude-opus-4",
                "provider": "openrouter",
                "upstream": "anthropic",
                "categories": ["confidence"],
            },
            {
                "id": "google/gemini-2.5-flash",
                "provider": "openrouter",
                "upstream": "google",
                "categories": ["performance", "cost"],
            },
            {
                "id": "meta-llama/llama-3.3-70b-instruct",
                "provider": "openrouter",
                "upstream": "meta",
                "categories": ["cost"],
            },
        ],
    }


@router.get("/meta/token-estimate")
async def token_estimate(text: str) -> dict:
    return {"estimated_tokens": estimate_tokens(text)}
