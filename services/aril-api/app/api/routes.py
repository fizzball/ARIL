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
from app.core.schemas import (
    ChatRequest,
    ChatResponse,
    ChatMessage,
    CompareRequest,
    CompareResponse,
    CompareResult,
    PreferRequest,
    PreferResponse,
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
from app.providers.messages import attachments_to_provider_messages
from app.routing.pipeline import (
    CATEGORY_RECOMMENDATIONS,
    DEFAULT_PROFILE,
    build_preview,
    classify,
    estimate_tokens,
    grade_prompt,
    resolve_profile,
    score_routes,
)
from app.routing.probe import probe_models
from app.routing.rewrite import llm_alternatives

router = APIRouter(prefix="/v1")


def _resolve_model(req_model: str | None, last_user: str, profile) -> tuple[str, object]:
    classification = classify(last_user)
    mapping = resolve_profile(profile) if profile is not None else DEFAULT_PROFILE
    model = req_model or mapping[classification.primary]
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
) -> tuple[ProviderResult, bool]:
    provider = get_chat_provider()
    provider_messages = attachments_to_provider_messages(messages, attachments or [])
    msg_dicts = _msg_dicts(messages)
    # Don't cache web search or multimodal turns (dynamic / large)
    cacheable = use_cache and not web_search and not attachments
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

    try:
        result, cached = await _complete_cached(
            messages=req.messages,
            model=model,
            temperature=temperature,
            use_cache=req.use_cache,
            attachments=req.attachments,
            web_search=req.web_search,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    session_id = req.session_id or str(uuid.uuid4())
    assistant = ChatMessage(role="assistant", content=result.content)
    session_store.upsert_session(
        SessionUpsert(
            id=session_id,
            title=last_user[:42] if last_user else "New session",
            messages=list(req.messages) + [assistant],
        )
    )

    return ChatResponse(
        session_id=session_id,
        message=assistant,
        model=result.model,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        cost_usd=result.cost_usd * (0.45 if cached else 1.0),
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
    msg_dicts = _msg_dicts(req.messages)
    est = estimate_tokens(last_user)
    key = prompt_cache.make_key(messages=msg_dicts, model=model, temperature=temperature)

    async def event_generator():
        stream_started = time.perf_counter()
        # Cache short-circuit for large prompts (skip when web/attachments)
        if req.use_cache and not req.web_search and not req.attachments and prompt_cache.eligible(est):
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
                session_store.upsert_session(
                    SessionUpsert(
                        id=session_id,
                        title=last_user[:42] if last_user else "New session",
                        messages=list(req.messages) + [assistant],
                    )
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
        if (
            req.use_cache
            and not req.web_search
            and not req.attachments
            and prompt_cache.eligible(int(meta["input_tokens"] or est))
        ):
            prompt_cache.put(
                key,
                {
                    "content": full,
                    "model": meta["model"],
                    "input_tokens": meta["input_tokens"],
                    "output_tokens": meta["output_tokens"],
                    "cost_usd": meta["cost_usd"],
                },
            )
        assistant = ChatMessage(role="assistant", content=full)
        session_store.upsert_session(
            SessionUpsert(
                id=session_id,
                title=last_user[:42] if last_user else "New session",
                messages=list(req.messages) + [assistant],
            )
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
    models = req.models or [r.model_id for r in routes[: settings.aril_compare_model_count]]
    # Deduplicate while preserving order
    seen: set[str] = set()
    models = [m for m in models if not (m in seen or seen.add(m))]
    if len(models) < 2:
        # Ensure at least two candidates
        for mid in profile.values():
            if mid not in seen:
                models.append(mid)
                seen.add(mid)
            if len(models) >= 2:
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
            return CompareResult(
                model=result.model,
                content=result.content,
                input_tokens=result.input_tokens,
                output_tokens=result.output_tokens,
                cost_usd=result.cost_usd * (0.45 if cached else 1.0),
                latency_ms=ms,
                probe_latency_ms=probe_map.get(model),
                cached=cached,
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
    # Persist a summary note into the session
    summary_bits = []
    for r in results:
        if r.error:
            summary_bits.append(f"### {r.model}\nError: {r.error}")
        else:
            probe_bit = f" · probe {r.probe_latency_ms}ms" if r.probe_latency_ms is not None else ""
            summary_bits.append(f"### {r.model} ({r.latency_ms}ms{probe_bit})\n{r.content}")
    assistant = ChatMessage(role="assistant", content="\n\n".join(summary_bits))
    session_store.upsert_session(
        SessionUpsert(
            id=session_id,
            title=f"Compare: {(last_user or 'prompt')[:32]}",
            messages=list(req.messages) + [assistant],
        )
    )
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
    category = req.category
    if category is None:
        category = classify(req.prompt).primary
    info = pref_store.record_preference(
        prompt=req.prompt, category=category.value, model=req.model
    )
    return PreferResponse(ok=True, **info)


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
