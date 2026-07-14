from __future__ import annotations

import asyncio
import json
import time
import uuid

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from app.core import cache as prompt_cache
from app.core import preferences as pref_store
from app.core import sessions as session_store
from app.core.config import settings
from app.core import secrets as key_store
from app.core.schemas import (
    ChatRequest,
    ChatResponse,
    ChatMessage,
    ClassificationRecord,
    ClassificationUpdateRequest,
    CompareRequest,
    CompareResponse,
    CompareResult,
    ModelPricingResponse,
    OpenRouterCatalogResponse,
    OpenRouterKeyStatus,
    OpenRouterKeyUpdate,
    PreferRequest,
    PreferResponse,
    PreferencesSnapshot,
    PreviewRequest,
    PreviewResponse,
    ProbeRequest,
    ProbeResponse,
    RouteCategory,
    SessionDetail,
    SessionSummary,
    SessionUpsert,
)
from app.providers.base import ProviderMessage, ProviderResult, get_chat_provider
from app.providers.messages import attachments_to_provider_messages, sanitize_content_for_context
from app.routing.pipeline import (
    CATEGORY_RECOMMENDATIONS,
    DEFAULT_PROFILE,
    IMAGE_GEN_MODEL,
    build_preview,
    classify,
    estimate_tokens,
    grade_prompt,
    resolve_profile,
    score_routes,
    wants_image_generation,
)
from app.routing.pricing import list_catalog, pricing_for_models, resolve_cost_usd
from app.routing.probe import probe_models
from app.routing.rewrite import llm_alternatives

router = APIRouter(prefix="/v1")


def _resolve_model(req_model: str | None, last_user: str, profile) -> tuple[str, object]:
    classification = classify(last_user)
    mapping = resolve_profile(profile) if profile is not None else DEFAULT_PROFILE
    model = req_model or mapping[classification.primary]
    if wants_image_generation(last_user):
        model_l = (model or "").lower()
        if not any(tok in model_l for tok in ("image", "flux", "dall-e", "dalle", "seedream", "sourceful")):
            model = IMAGE_GEN_MODEL
    return model, classification


def _msg_dicts(messages: list[ChatMessage]) -> list[dict[str, str]]:
    return [{"role": m.role, "content": m.content} for m in messages]


async def _complete_cached(
    *,
    messages: list[ChatMessage],
    model: str,
    temperature: float,
    use_cache: bool,
    attachments: list | None = None,
    web_search: bool = False,
    generate_image: bool = False,
) -> tuple[ProviderResult, bool]:
    provider = get_chat_provider()
    provider_messages = attachments_to_provider_messages(messages, attachments or [])
    msg_dicts = _msg_dicts(messages)
    # Don't cache web search, multimodal, or image generation turns
    cacheable = use_cache and not web_search and not attachments and not generate_image
    est = estimate_tokens(" ".join(m.content for m in messages))
    key = prompt_cache.make_key(
        messages=msg_dicts,
        model=model,
        temperature=temperature,
    )

    if cacheable and prompt_cache.eligible(est):
        hit = prompt_cache.peek(key)
        if hit:
            return (
                ProviderResult(
                    content=hit["content"],
                    model=hit.get("model") or model,
                    input_tokens=int(hit.get("input_tokens") or est),
                    output_tokens=int(hit.get("output_tokens") or 0),
                    cost_usd=float(hit.get("cost_usd") or 0.0),
                    cached=True,
                ),
                True,
            )

    result = await provider.complete(
        provider_messages,
        model=model,
        temperature=temperature,
        web_search=web_search,
        generate_image=generate_image,
    )
    if cacheable and prompt_cache.eligible(result.input_tokens or est):
        prompt_cache.put(
            key,
            {
                "content": result.content,
                "model": result.model,
                "input_tokens": result.input_tokens,
                "output_tokens": result.output_tokens,
                "cost_usd": result.cost_usd,
            },
        )
    return result, False


@router.post("/preview", response_model=PreviewResponse)
async def preview(req: PreviewRequest) -> PreviewResponse:
    """Classify, grade, optionally LLM-rewrite alternatives, rank routes."""
    grade = grade_prompt(req.prompt)
    alts = None
    source = "heuristic"
    if req.enhance_alternatives and grade.overall < 0.78:
        alts = await llm_alternatives(req.prompt, grade)
        if settings.openrouter_api_key.strip() and alts and any(
            a.id.startswith("llm-") for a in alts
        ):
            source = "llm"
    return build_preview(req, alternatives=alts, alternatives_source=source)


@router.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    """Execute a chat turn via OpenRouter (or stub if no key), with optional cache."""
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    model, classification = _resolve_model(req.model, last_user, req.routing_profile)
    temperature = (
        req.temperature if req.temperature is not None else settings.aril_default_temperature
    )
    generate_image = wants_image_generation(last_user)

    try:
        result, cached = await _complete_cached(
            messages=req.messages,
            model=model,
            temperature=temperature,
            use_cache=req.use_cache,
            attachments=req.attachments,
            web_search=req.web_search,
            generate_image=generate_image,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    session_id = req.session_id or str(uuid.uuid4())
    # Return full content to the client (may include generated image data URLs).
    assistant = ChatMessage(role="assistant", content=result.content)
    session_store.record_chat_turn(
        session_id,
        title=last_user[:42] if last_user else "New session",
        user_content=last_user,
        assistant_content=result.content,
    )

    resolved_cost = resolve_cost_usd(
        result.model,
        reported_cost=result.cost_usd,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        web_search=req.web_search,
    )
    return ChatResponse(
        session_id=session_id,
        message=assistant,
        model=result.model,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        cost_usd=resolved_cost * (0.45 if cached else 1.0),
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
    generate_image = wants_image_generation(last_user)
    session_id = req.session_id or str(uuid.uuid4())
    msg_dicts = _msg_dicts(req.messages)
    est = estimate_tokens(last_user)
    key = prompt_cache.make_key(messages=msg_dicts, model=model, temperature=temperature)

    async def event_generator():
        stream_started = time.perf_counter()
        # Cache short-circuit for large prompts (skip when web/attachments/image-gen)
        if (
            req.use_cache
            and not req.web_search
            and not req.attachments
            and not generate_image
            and prompt_cache.eligible(est)
        ):
            hit = prompt_cache.peek(key)
            if hit:
                content = hit["content"]
                payload = json.dumps({"content": content, "model": hit.get("model") or model})
                yield f"event: token\ndata: {payload}\n\n"
                meta = {
                    "session_id": session_id,
                    "model": hit.get("model") or model,
                    "route_category": classification.primary.value,
                    "input_tokens": int(hit.get("input_tokens") or est),
                    "output_tokens": int(hit.get("output_tokens") or 0),
                    "cost_usd": float(hit.get("cost_usd") or 0.0) * 0.45,
                    "cached": True,
                    "latency_ms": int((time.perf_counter() - stream_started) * 1000),
                }
                assistant = ChatMessage(role="assistant", content=content)
                session_store.record_chat_turn(
                    session_id,
                    title=last_user[:42] if last_user else "New session",
                    user_content=last_user,
                    assistant_content=content,
                )
                yield f"event: done\ndata: {json.dumps(meta)}\n\n"
                return

        provider = get_chat_provider()
        provider_messages = attachments_to_provider_messages(req.messages, req.attachments)
        parts: list[str] = []
        meta = {
            "session_id": session_id,
            "model": model,
            "route_category": classification.primary.value,
            "input_tokens": 0,
            "output_tokens": 0,
            "cost_usd": 0.0,
            "cached": False,
            "web_search": req.web_search,
        }
        try:
            async for chunk in provider.stream(
                provider_messages,
                model=model,
                temperature=temperature,
                web_search=req.web_search,
                generate_image=generate_image,
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
        # Persist a slim copy so later turns don't rehydrate multi-hundred-kB base64 images.
        stored_full = sanitize_content_for_context(full)
        if (
            req.use_cache
            and not req.web_search
            and not req.attachments
            and not generate_image
            and prompt_cache.eligible(int(meta["input_tokens"] or est))
        ):
            prompt_cache.put(
                key,
                {
                    "content": stored_full,
                    "model": meta["model"],
                    "input_tokens": meta["input_tokens"],
                    "output_tokens": meta["output_tokens"],
                    "cost_usd": meta["cost_usd"],
                },
            )
        # Client still received the full streamed content (including images) above.
        session_store.record_chat_turn(
            session_id,
            title=last_user[:42] if last_user else "New session",
            user_content=last_user,
            assistant_content=stored_full,
        )
        meta["cost_usd"] = resolve_cost_usd(
            str(meta.get("model") or model),
            reported_cost=float(meta.get("cost_usd") or 0.0),
            input_tokens=int(meta.get("input_tokens") or 0),
            output_tokens=int(meta.get("output_tokens") or 0),
            web_search=bool(req.web_search),
        )
        meta["latency_ms"] = int((time.perf_counter() - stream_started) * 1000)
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


@router.post("/compare", response_model=CompareResponse)
async def compare(req: CompareRequest) -> CompareResponse:
    """Run the same prompt across multiple models and return side-by-side results."""
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    classification = classify(last_user)
    temperature = (
        req.temperature if req.temperature is not None else settings.aril_default_temperature
    )
    profile = resolve_profile(req.routing_profile)
    routes = score_routes(last_user or " ", classification.primary, profile)
    target_count = max(3, settings.aril_compare_model_count)
    models = req.models or [r.model_id for r in routes[:target_count]]
    # Deduplicate while preserving order
    seen: set[str] = set()
    models = [m for m in models if not (m in seen or seen.add(m))]
    if len(models) < target_count:
        for mid in profile.values():
            if mid not in seen:
                models.append(mid)
                seen.add(mid)
            if len(models) >= target_count:
                break

    session_id = req.session_id or str(uuid.uuid4())

    probe_map: dict[str, int] = {}
    probe_rows: list[dict] = []
    if req.run_probe:
        probe = await probe_models(ProbeRequest(models=models))
        for row in probe.results:
            probe_map[row.model] = row.latency_ms
            probe_rows.append(row.model_dump())

    async def run_one(model: str) -> CompareResult:
        started = time.perf_counter()
        try:
            result, cached = await _complete_cached(
                messages=req.messages,
                model=model,
                temperature=temperature,
                use_cache=req.use_cache,
            )
            ms = int((time.perf_counter() - started) * 1000)
            # Classify the *response* to suggest which category the answer best fits.
            resp_class = classify(result.content or last_user or " ")
            resolved = resolve_cost_usd(
                result.model,
                reported_cost=result.cost_usd,
                input_tokens=result.input_tokens,
                output_tokens=result.output_tokens,
            )
            return CompareResult(
                model=result.model,
                content=result.content,
                input_tokens=result.input_tokens,
                output_tokens=result.output_tokens,
                cost_usd=resolved * (0.45 if cached else 1.0),
                latency_ms=ms,
                probe_latency_ms=probe_map.get(model),
                cached=cached,
                suggested_category=resp_class.primary,
                category_confidence=resp_class.confidence,
            )
        except Exception as exc:  # noqa: BLE001
            ms = int((time.perf_counter() - started) * 1000)
            return CompareResult(
                model=model,
                content="",
                input_tokens=0,
                output_tokens=0,
                cost_usd=0.0,
                latency_ms=ms,
                probe_latency_ms=probe_map.get(model),
                error=str(exc),
            )

    results = await asyncio.gather(*[run_one(m) for m in models])
    # Do not rewrite session history with a 3-model dump. The client commits
    # the preferred user/assistant turn when the user picks Prefer.
    return CompareResponse(
        session_id=session_id,
        route_category=classification.primary,
        results=list(results),
        probe=probe_rows,
    )


@router.post("/probe", response_model=ProbeResponse)
async def probe(req: ProbeRequest) -> ProbeResponse:
    return await probe_models(req)


@router.post("/feedback/prefer", response_model=PreferResponse)
async def prefer(req: PreferRequest) -> PreferResponse:
    auto_category = classify(req.prompt).primary
    category = req.category or auto_category
    overridden = bool(req.category_overridden or (req.category is not None and req.category != auto_category))
    info = pref_store.record_preference(
        prompt=req.prompt,
        category=category.value,
        model=req.model,
        accuracy=req.accuracy,
        category_overridden=overridden,
    )
    return PreferResponse(ok=True, **info)


@router.get("/preferences", response_model=PreferencesSnapshot)
async def preferences_get() -> PreferencesSnapshot:
    snap = pref_store.snapshot()
    return PreferencesSnapshot(**snap)


@router.patch("/preferences/classifications/{classification_id}", response_model=ClassificationRecord)
async def preferences_update_classification(
    classification_id: str, req: ClassificationUpdateRequest
) -> ClassificationRecord:
    updated = pref_store.update_classification(
        classification_id,
        category=req.category.value if req.category else None,
        accuracy=req.accuracy,
        model=req.model,
        remove_accuracy=req.remove_accuracy,
    )
    if not updated:
        raise HTTPException(status_code=404, detail="Classification not found")
    return ClassificationRecord(**updated)


@router.delete("/preferences/classifications/{classification_id}")
async def preferences_delete_classification(classification_id: str) -> dict:
    if not pref_store.delete_classification(classification_id):
        raise HTTPException(status_code=404, detail="Classification not found")
    return {"ok": True}


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
    detail = session_store.upsert_session(payload)
    if detail is None:
        raise HTTPException(status_code=410, detail="Session was deleted")
    return detail


@router.delete("/sessions/{session_id}")
async def sessions_delete(session_id: str) -> dict:
    session_store.delete_session(session_id)
    return {"ok": True}


@router.delete("/sessions")
async def sessions_delete_all() -> dict:
    count = session_store.delete_all_sessions()
    return {"ok": True, "deleted": count}


@router.get("/settings/openrouter-key", response_model=OpenRouterKeyStatus)
async def openrouter_key_status() -> OpenRouterKeyStatus:
    return OpenRouterKeyStatus(**key_store.status())


@router.put("/settings/openrouter-key", response_model=OpenRouterKeyStatus)
async def openrouter_key_put(req: OpenRouterKeyUpdate) -> OpenRouterKeyStatus:
    try:
        return OpenRouterKeyStatus(**key_store.set_api_key(req.api_key))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.delete("/settings/openrouter-key", response_model=OpenRouterKeyStatus)
async def openrouter_key_delete() -> OpenRouterKeyStatus:
    return OpenRouterKeyStatus(**key_store.clear_api_key())


@router.get("/models/pricing", response_model=ModelPricingResponse)
async def models_pricing(ids: str = "", refresh: bool = False) -> ModelPricingResponse:
    """USD / 1K token rates from OpenRouter for the given model ids (comma-separated)."""
    requested = [part.strip() for part in ids.split(",") if part.strip()]
    if not requested:
        # Default to category-profile + catalog models.
        requested = sorted(
            {
                *DEFAULT_PROFILE.values(),
                *[m for models in CATEGORY_RECOMMENDATIONS.values() for m in models],
                IMAGE_GEN_MODEL,
            }
        )
    rows = pricing_for_models(requested, force_refresh=refresh)
    return ModelPricingResponse(models=rows, refreshed=refresh)


@router.get("/models/catalog", response_model=OpenRouterCatalogResponse)
async def models_catalog(q: str = "", refresh: bool = False) -> OpenRouterCatalogResponse:
    """Full OpenRouter model list with pricing (optional `q` search filter)."""
    rows = list_catalog(query=q or None, force_refresh=refresh)
    return OpenRouterCatalogResponse(models=rows, count=len(rows), refreshed=refresh)


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
                "categories": ["coding", "general", "reasoning"],
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
                "categories": ["security", "coding"],
            },
            {
                "id": "anthropic/claude-opus-4",
                "provider": "openrouter",
                "upstream": "anthropic",
                "categories": ["confidence", "reasoning"],
            },
            {
                "id": "google/gemini-2.5-flash",
                "provider": "openrouter",
                "upstream": "google",
                "categories": ["vision", "performance", "cost"],
            },
            {
                "id": "meta-llama/llama-3.3-70b-instruct",
                "provider": "openrouter",
                "upstream": "meta",
                "categories": ["general", "cost"],
            },
        ],
        "categories": {
            cat.value: {
                "label": cat.value.replace("_", " ").title(),
                "recommended_models": CATEGORY_RECOMMENDATIONS.get(cat, []),
                "default_model": DEFAULT_PROFILE.get(cat),
            }
            for cat in RouteCategory
        },
    }


@router.get("/meta/token-estimate")
async def token_estimate(text: str) -> dict:
    return {"estimated_tokens": estimate_tokens(text)}
