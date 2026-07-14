from __future__ import annotations

import json
import uuid

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from app.core import sessions as session_store
from app.core.config import settings
from app.core.schemas import (
    ChatRequest,
    ChatResponse,
    ChatMessage,
    PreviewRequest,
    PreviewResponse,
    SessionDetail,
    SessionSummary,
    SessionUpsert,
)
from app.providers.base import ProviderMessage, get_chat_provider
from app.routing.pipeline import DEFAULT_PROFILE, build_preview, classify, estimate_tokens, resolve_profile

router = APIRouter(prefix="/v1")


def _resolve_model(req_model: str | None, last_user: str, profile) -> tuple[str, object]:
    classification = classify(last_user)
    mapping = resolve_profile(profile) if profile is not None else DEFAULT_PROFILE
    model = req_model or mapping[classification.primary]
    return model, classification


@router.post("/preview", response_model=PreviewResponse)
async def preview(req: PreviewRequest) -> PreviewResponse:
    """Classify, grade, suggest alternatives, and rank routes — no provider call."""
    return build_preview(req)


@router.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    """Execute a chat turn via OpenRouter (or stub if no key)."""
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    model, classification = _resolve_model(req.model, last_user, req.routing_profile)

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

    session_id = req.session_id or str(uuid.uuid4())
    title = None
    if last_user:
        title = last_user[:42] if not req.session_id else None

    # Persist the latest assistant turn (and user if last message is user)
    user_msg = req.messages[-1] if req.messages and req.messages[-1].role == "user" else None
    assistant = ChatMessage(role="assistant", content=result.content)
    if user_msg is not None:
        # If client sent full history, store the whole thread
        session_store.upsert_session(
            SessionUpsert(
                id=session_id,
                title=title or (last_user[:42] if last_user else "New session"),
                messages=list(req.messages) + [assistant],
            )
        )
    else:
        session_store.append_turn(session_id, title=title, user=None, assistant=assistant)

    in_tok = result.input_tokens
    cached = bool(req.use_cache and in_tok > settings.aril_cache_token_threshold)

    return ChatResponse(
        session_id=session_id,
        message=assistant,
        model=result.model,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        cost_usd=result.cost_usd * (0.55 if cached else 1.0),
        cached=cached,
        route_category=classification.primary,
    )


@router.post("/chat/stream")
async def chat_stream(req: ChatRequest) -> StreamingResponse:
    """SSE stream of assistant tokens, ending with a `done` event."""
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    model, classification = _resolve_model(req.model, last_user, req.routing_profile)
    temperature = (
        req.temperature if req.temperature is not None else settings.aril_default_temperature
    )
    session_id = req.session_id or str(uuid.uuid4())
    provider = get_chat_provider()
    provider_messages = [ProviderMessage(role=m.role, content=m.content) for m in req.messages]

    async def event_generator():
        parts: list[str] = []
        meta = {
            "session_id": session_id,
            "model": model,
            "route_category": classification.primary.value,
            "input_tokens": 0,
            "output_tokens": 0,
            "cost_usd": 0.0,
        }
        try:
            async for chunk in provider.stream(
                provider_messages, model=model, temperature=temperature
            ):
                if chunk.content:
                    parts.append(chunk.content)
                    payload = json.dumps({"content": chunk.content, "model": chunk.model or model})
                    yield f"event: token\ndata: {payload}\n\n"
                if chunk.input_tokens or chunk.output_tokens or chunk.cost_usd:
                    meta["input_tokens"] = chunk.input_tokens or meta["input_tokens"]
                    meta["output_tokens"] = chunk.output_tokens or meta["output_tokens"]
                    meta["cost_usd"] = chunk.cost_usd or meta["cost_usd"]
                    if chunk.model:
                        meta["model"] = chunk.model
                if chunk.done:
                    break
        except RuntimeError as exc:
            err = json.dumps({"error": str(exc)})
            yield f"event: error\ndata: {err}\n\n"
            return

        full = "".join(parts)
        assistant = ChatMessage(role="assistant", content=full)
        session_store.upsert_session(
            SessionUpsert(
                id=session_id,
                title=last_user[:42] if last_user else "New session",
                messages=list(req.messages) + [assistant],
            )
        )
        meta["cached"] = bool(
            req.use_cache and meta["input_tokens"] > settings.aril_cache_token_threshold
        )
        yield f"event: done\ndata: {json.dumps(meta)}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.get("/sessions", response_model=list[SessionSummary])
async def sessions_list() -> list[SessionSummary]:
    return session_store.list_sessions()


@router.get("/sessions/{session_id}", response_model=SessionDetail)
async def sessions_get(session_id: str) -> SessionDetail:
    detail = session_store.get_session(session_id)
    if not detail:
        raise HTTPException(status_code=404, detail="Session not found")
    return detail


@router.put("/sessions", response_model=SessionDetail)
async def sessions_put(payload: SessionUpsert) -> SessionDetail:
    return session_store.upsert_session(payload)


@router.delete("/sessions/{session_id}")
async def sessions_delete(session_id: str) -> dict:
    if not session_store.delete_session(session_id):
        raise HTTPException(status_code=404, detail="Session not found")
    return {"ok": True}


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
