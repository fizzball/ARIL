from __future__ import annotations

import asyncio
import json
import time
import uuid

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from app.core import analysis_cache as analysis_store
from app.core import cache as prompt_cache
from app.core import db as local_db
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
    OpenRouterConnectionStatus,
    OpenRouterKeyStatus,
    OpenRouterKeyUpdate,
    OpenRouterWeeklyRankingsResponse,
    MCPCheckRequest,
    MCPCheckResponse,
    PreferRequest,
    PreferResponse,
    PreferencesSnapshot,
    PreviewRequest,
    PreviewResponse,
    ProbeRequest,
    ProbeResponse,
    PromptAlternative,
    RouteCategory,
    RouteMode,
    SessionDetail,
    SessionSummary,
    SessionUpsert,
    StoreDeleteAllResponse,
    StoreRecord,
    StoreRetentionUpdate,
    StoreStats,
    StoreStatus,
)
from app.providers.base import ProviderMessage, ProviderResult, get_chat_provider
from app.providers.messages import attachments_to_provider_messages, sanitize_content_for_context
from app.routing.pipeline import (
    CATEGORY_RECOMMENDATIONS,
    DEFAULT_PROFILE,
    IMAGE_GEN_MODEL,
    build_preview,
    build_preview_from_judgement,
    classify,
    estimate_tokens,
    grade_prompt,
    resolve_profile,
    score_routes,
    select_judge_models,
    wants_image_generation,
)
from app.routing.pricing import list_catalog, list_weekly_rankings, pricing_for_models, resolve_cost_usd
from app.routing.probe import probe_models
from app.routing.rewrite import llm_alternatives
from app.mcp import (
    MCPServerSpec,
    check_remote_mcp,
    close_mcp_bundle,
    open_mcp_bundle,
    run_mcp_tool_rounds,
)

router = APIRouter(prefix="/v1")


def _resolve_model(
    req_model: str | None,
    last_user: str,
    profile,
    *,
    route_mode: RouteMode = RouteMode.auto,
) -> tuple[str, object, str | None]:
    classification = classify(last_user)
    mapping = resolve_profile(profile) if profile is not None else DEFAULT_PROFILE
    preference_reason: str | None = None

    if route_mode == RouteMode.manual and req_model:
        # Manual is the only mode that honors the client-supplied model lock.
        model = req_model
    elif route_mode == RouteMode.auto:
        # Never use req_model here — the Mac client keeps `selectedModel` as the
        # last Manual pick until preview refreshes it, which made Auto look stuck.
        pick = pref_store.preferred_model_for_prompt(
            last_user, classification.primary.value
        )
        if pick:
            model = pick["model"]
            preference_reason = pick.get("reason")
        else:
            model = mapping[classification.primary]
    else:
        model = req_model or mapping[classification.primary]

    if wants_image_generation(last_user):
        model_l = (model or "").lower()
        if not any(tok in model_l for tok in ("image", "flux", "dall-e", "dalle", "seedream", "sourceful")):
            model = IMAGE_GEN_MODEL
    return model, classification, preference_reason


def _msg_dicts(messages: list[ChatMessage]) -> list[dict[str, str]]:
    return [{"role": m.role, "content": m.content} for m in messages]


def _inject_model_identity(provider_messages: list, model: str) -> list:
    """Tell the model its real OpenRouter id so identity questions don’t hallucinate."""
    mid = (model or "").strip()
    if not mid or not provider_messages:
        return provider_messages
    note = (
        f"Authoritative runtime note: this turn is served by OpenRouter model id `{mid}`. "
        "If asked which model you are (name, version, or provider), answer with that exact id. "
        "Do not claim to be Claude, GPT, Gemini, or any other model unless that id matches."
    )
    from app.providers.base import ProviderMessage

    out = list(provider_messages)
    first = out[0]
    role = getattr(first, "role", None)
    content = getattr(first, "content", None)
    if role == "system" and isinstance(content, str):
        out[0] = ProviderMessage(role="system", content=f"{content.rstrip()}\n\n{note}")
    else:
        out.insert(0, ProviderMessage(role="system", content=note))
    return out


def _auto_judgement_after_send(
    *,
    prompt: str,
    category: str,
    model: str,
    route_mode: RouteMode,
    skip: bool = False,
) -> None:
    """First successful Auto (or Compare) send seeds Learning like Prefer would.

    Manual mode never writes judgements — the locked model is not a routing opinion.
    Early Enter (before analysis idle) also skips so Learning is not seeded from
    an un-analysed prompt.
    """
    if skip or route_mode == RouteMode.manual:
        return
    try:
        pref_store.ensure_auto_judgement(
            prompt=prompt,
            category=category,
            model=model,
        )
    except Exception:  # noqa: BLE001 — never fail the chat turn on learning write
        pass


async def _complete_cached(
    *,
    messages: list[ChatMessage],
    model: str,
    temperature: float,
    use_cache: bool,
    attachments: list | None = None,
    web_search: bool = False,
    generate_image: bool = False,
    mcp_servers: list | None = None,
) -> tuple[ProviderResult, bool]:
    provider = get_chat_provider()
    provider_messages = _inject_model_identity(
        attachments_to_provider_messages(messages, attachments or []),
        model,
    )
    msg_dicts = _msg_dicts(messages)
    mcp_specs = _mcp_specs(mcp_servers)
    # Don't cache web search, multimodal, image generation, or MCP tool turns
    cacheable = (
        use_cache
        and not web_search
        and not attachments
        and not generate_image
        and not mcp_specs
    )
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

    if mcp_specs:
        bundle = await open_mcp_bundle(mcp_specs)
        try:
            _, result = await run_mcp_tool_rounds(
                provider,
                provider_messages,
                model=model,
                temperature=temperature,
                web_search=web_search,
                generate_image=generate_image,
                bundle=bundle,
            )
        finally:
            await close_mcp_bundle(bundle)
    else:
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


def _mcp_specs(servers: list | None) -> list[MCPServerSpec]:
    if not servers:
        return []
    out: list[MCPServerSpec] = []
    for s in servers:
        url = (getattr(s, "url", None) or "").strip()
        if not url:
            continue
        out.append(
            MCPServerSpec(
                id=str(getattr(s, "id", "") or ""),
                name=str(getattr(s, "name", "") or ""),
                url=url,
                auth_style=str(getattr(s, "auth_style", None) or "bearer"),
                auth_header_name=getattr(s, "auth_header_name", None),
                api_key=getattr(s, "api_key", None),
            )
        )
    return out


@router.post("/preview", response_model=PreviewResponse)
async def preview(req: PreviewRequest) -> PreviewResponse:
    """Classify, grade, optionally LLM-rewrite alternatives, rank routes."""
    profile_dict = req.routing_profile.model_dump() if req.routing_profile else None

    # Token saver: reuse Learning judgement without re-analysis / rewrite LLM.
    if req.skip_analysis_on_judgement:
        override = pref_store.lookup_classification(req.prompt)
        if override:
            cached = analysis_store.get(
                req.prompt,
                routing_profile=profile_dict,
                system_prompt=req.system_prompt,
                enhance_alternatives=req.enhance_alternatives,
            )
            payload = (
                cached.get("payload")
                if cached and isinstance(cached.get("payload"), dict)
                else None
            )
            return build_preview_from_judgement(
                req, override, cached_payload=payload
            )

    cached = analysis_store.get(
        req.prompt,
        routing_profile=profile_dict,
        system_prompt=req.system_prompt,
        enhance_alternatives=req.enhance_alternatives,
    )
    # Redo Analysis must rebuild (and may refresh the Learning judgement).
    if cached and isinstance(cached.get("payload"), dict) and not req.update_judgement:
        payload = cached["payload"]
        alts_raw = payload.get("alternatives") or []
        alts = [PromptAlternative(**a) for a in alts_raw if isinstance(a, dict)]
        source = "cache"
        resp = build_preview(req, alternatives=alts, alternatives_source=source)
        # Restore recommended model from cache when present (same context).
        recommended = payload.get("recommended_model")
        if recommended and isinstance(recommended, str):
            resp = resp.model_copy(update={"recommended_model": recommended})
        return resp

    grade = grade_prompt(req.prompt)
    alts = None
    source = "heuristic"
    if req.enhance_alternatives and grade.overall < 0.78:
        alts = await llm_alternatives(req.prompt, grade)
        if settings.openrouter_api_key.strip() and alts and any(
            a.id.startswith("llm-") for a in alts
        ):
            source = "llm"
    resp = build_preview(req, alternatives=alts, alternatives_source=source)
    # Persist analysis snapshot for Learning browser + like-prompt reuse.
    analysis_store.put(
        req.prompt,
        {
            "alternatives": [a.model_dump() for a in resp.alternatives],
            "recommended_model": resp.recommended_model,
            "category": resp.classification.primary.value,
            "alternatives_source": resp.alternatives_source,
            "grade": resp.grade.model_dump(),
        },
        routing_profile=profile_dict,
        system_prompt=req.system_prompt,
        enhance_alternatives=req.enhance_alternatives,
    )
    if req.update_judgement and req.route_mode != RouteMode.manual:
        existing = pref_store.lookup_classification(req.prompt)
        pref_store.record_preference(
            prompt=req.prompt,
            category=resp.classification.primary.value,
            model=resp.recommended_model,
            accuracy=existing.get("accuracy") if existing else None,
            category_overridden=bool(existing.get("category_overridden")) if existing else False,
        )
        # Refresh override insight on the response after upsert.
        refreshed = pref_store.lookup_classification(req.prompt)
        if refreshed:
            from app.core.schemas import UserOverrideInsight

            try:
                ov_cat = RouteCategory(refreshed["category"])
                resp = resp.model_copy(
                    update={
                        "user_override": UserOverrideInsight(
                            classification_id=refreshed["id"],
                            category=ov_cat,
                            model=refreshed.get("model"),
                            accuracy=refreshed.get("accuracy"),
                            category_overridden=bool(refreshed.get("category_overridden")),
                            prompt_snippet=refreshed.get("prompt_snippet"),
                        )
                    }
                )
            except ValueError:
                pass
    return resp


@router.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    """Execute a chat turn via OpenRouter (or stub if no key), with optional cache."""
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    model, classification, preference_reason = _resolve_model(
        req.model,
        last_user,
        req.routing_profile,
        route_mode=req.route_mode,
    )
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
            mcp_servers=req.mcp_servers,
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
    final_cost = resolved_cost * (0.45 if cached else 1.0)
    analysis_store.record_chat_transaction(
        session_id=session_id,
        prompt=last_user,
        model=result.model,
        category=classification.primary.value,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        cost_usd=final_cost,
        cached=cached,
        analysis={
            "route_category": classification.primary.value,
            "temperature": temperature,
            "preference_reason": preference_reason,
        },
    )
    _auto_judgement_after_send(
        prompt=last_user,
        category=classification.primary.value,
        model=result.model,
        route_mode=req.route_mode,
        skip=req.skip_auto_judgement,
    )
    return ChatResponse(
        session_id=session_id,
        message=assistant,
        model=result.model,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        cost_usd=final_cost,
        cached=cached,
        route_category=classification.primary,
        preference_reason=preference_reason,
    )


@router.post("/chat/stream")
async def chat_stream(req: ChatRequest) -> StreamingResponse:
    """SSE stream of assistant tokens, ending with a `done` event."""
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    model, classification, preference_reason = _resolve_model(
        req.model,
        last_user,
        req.routing_profile,
        route_mode=req.route_mode,
    )
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
        mcp_specs = _mcp_specs(req.mcp_servers)
        # Cache short-circuit for large prompts (skip when web/attachments/image-gen/MCP)
        if (
            req.use_cache
            and not req.web_search
            and not req.attachments
            and not generate_image
            and not mcp_specs
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
                    "preference_reason": preference_reason,
                }
                session_store.record_chat_turn(
                    session_id,
                    title=last_user[:42] if last_user else "New session",
                    user_content=last_user,
                    assistant_content=content,
                )
                analysis_store.record_chat_transaction(
                    session_id=session_id,
                    prompt=last_user,
                    model=str(meta["model"]),
                    category=classification.primary.value,
                    input_tokens=int(meta["input_tokens"]),
                    output_tokens=int(meta["output_tokens"]),
                    cost_usd=float(meta["cost_usd"]),
                    cached=True,
                    analysis={"route_category": classification.primary.value, "stream": True},
                )
                _auto_judgement_after_send(
                    prompt=last_user,
                    category=classification.primary.value,
                    model=str(meta["model"]),
                    route_mode=req.route_mode,
                    skip=req.skip_auto_judgement,
                )
                yield f"event: done\ndata: {json.dumps(meta)}\n\n"
                return

        provider = get_chat_provider()
        provider_messages = _inject_model_identity(
            attachments_to_provider_messages(req.messages, req.attachments),
            model,
        )
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
            "preference_reason": preference_reason,
        }

        # MCP tool loop (non-stream rounds) then stream final text.
        if mcp_specs:
            bundle = None
            status_q: asyncio.Queue[dict[str, str] | None] = asyncio.Queue()

            async def on_status(evt: dict[str, str]) -> None:
                await status_q.put(evt)

            async def run_tools() -> tuple[list, ProviderResult]:
                nonlocal bundle
                try:
                    for spec in mcp_specs:
                        await on_status(
                            {
                                "server": (spec.name or "MCP").strip() or "MCP",
                                "tool": "connect",
                                "phase": "preparing",
                            }
                        )
                    bundle = await open_mcp_bundle(mcp_specs)
                    await on_status(
                        {
                            "server": "MCP",
                            "tool": "model",
                            "phase": "preparing",
                        }
                    )
                    return await run_mcp_tool_rounds(
                        provider,
                        provider_messages,
                        model=model,
                        temperature=temperature,
                        web_search=req.web_search,
                        generate_image=generate_image,
                        bundle=bundle,
                        on_status=on_status,
                    )
                finally:
                    await status_q.put(None)

            tool_task = asyncio.create_task(run_tools())
            try:
                while True:
                    evt = await status_q.get()
                    if evt is None:
                        break
                    yield f"event: mcp_status\ndata: {json.dumps(evt)}\n\n"
                working_messages, tool_result = await tool_task
            except Exception as exc:
                if not tool_task.done():
                    tool_task.cancel()
                err = json.dumps({"error": str(exc) or "MCP tool loop failed"})
                yield f"event: error\ndata: {err}\n\n"
                return
            finally:
                await close_mcp_bundle(bundle)

            meta["input_tokens"] = tool_result.input_tokens
            meta["output_tokens"] = tool_result.output_tokens
            meta["cost_usd"] = tool_result.cost_usd
            if tool_result.model:
                meta["model"] = tool_result.model

            # Tool loop already produced the final text via non-stream completes.
            if (tool_result.content or "").strip():
                parts.append(tool_result.content)
                payload = json.dumps(
                    {"content": tool_result.content, "model": tool_result.model or model}
                )
                yield f"event: token\ndata: {payload}\n\n"
            else:
                try:
                    async for chunk in provider.stream(
                        working_messages,
                        model=model,
                        temperature=temperature,
                        web_search=req.web_search,
                        generate_image=generate_image,
                    ):
                        if chunk.content:
                            parts.append(chunk.content)
                            payload = json.dumps(
                                {"content": chunk.content, "model": chunk.model or model}
                            )
                            yield f"event: token\ndata: {payload}\n\n"
                        if chunk.input_tokens or chunk.output_tokens or chunk.cost_usd:
                            meta["input_tokens"] = (
                                int(meta["input_tokens"] or 0) + (chunk.input_tokens or 0)
                            )
                            meta["output_tokens"] = (
                                int(meta["output_tokens"] or 0) + (chunk.output_tokens or 0)
                            )
                            meta["cost_usd"] = float(meta["cost_usd"] or 0) + float(
                                chunk.cost_usd or 0
                            )
                            if chunk.model:
                                meta["model"] = chunk.model
                        if chunk.done:
                            break
                except Exception as exc:
                    err = json.dumps({"error": str(exc) or "Upstream stream failed"})
                    yield f"event: error\ndata: {err}\n\n"
                    return
        else:
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
            except Exception as exc:
                # Broad catch: httpx/network errors used to tear down the body with
                # neither `error` nor `done`, which surfaced as client "Try again".
                err = json.dumps({"error": str(exc) or "Upstream stream failed"})
                yield f"event: error\ndata: {err}\n\n"
                return

        full = "".join(parts)
        # Empty upstream stream — one non-stream completion before failing closed.
        if not full.strip():
            try:
                result = await provider.complete(
                    provider_messages,
                    model=model,
                    temperature=temperature,
                    web_search=req.web_search,
                    generate_image=generate_image,
                )
            except Exception as exc:
                err = json.dumps({"error": str(exc) or "Model returned an empty response"})
                yield f"event: error\ndata: {err}\n\n"
                return
            if not (result.content or "").strip():
                err = json.dumps({"error": "Model returned an empty response. Try sending again."})
                yield f"event: error\ndata: {err}\n\n"
                return
            full = result.content
            parts = [full]
            payload = json.dumps({"content": full, "model": result.model or model})
            yield f"event: token\ndata: {payload}\n\n"
            meta["input_tokens"] = result.input_tokens or meta["input_tokens"]
            meta["output_tokens"] = result.output_tokens or meta["output_tokens"]
            meta["cost_usd"] = result.cost_usd or meta["cost_usd"]
            if result.model:
                meta["model"] = result.model
        # Persist a slim copy so later turns don't rehydrate multi-hundred-kB base64 images.
        stored_full = sanitize_content_for_context(full)
        if (
            req.use_cache
            and not req.web_search
            and not req.attachments
            and not generate_image
            and not mcp_specs
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
        analysis_store.record_chat_transaction(
            session_id=session_id,
            prompt=last_user,
            model=str(meta.get("model") or model),
            category=classification.primary.value,
            input_tokens=int(meta.get("input_tokens") or 0),
            output_tokens=int(meta.get("output_tokens") or 0),
            cost_usd=float(meta.get("cost_usd") or 0.0),
            cached=False,
            analysis={"route_category": classification.primary.value, "stream": True},
        )
        _auto_judgement_after_send(
            prompt=last_user,
            category=classification.primary.value,
            model=str(meta.get("model") or model),
            route_mode=req.route_mode,
            skip=req.skip_auto_judgement,
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


@router.post("/compare", response_model=CompareResponse)
async def compare(req: CompareRequest) -> CompareResponse:
    """Run the same prompt across capability-matched models and return side-by-side results.

    Classifies the user prompt, then judges the profile model for that category
    against two peers that share the same capability (e.g. three Vision models).
    Explicit `models` still overrides for tests / advanced clients.
    """
    last_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    classification = classify(last_user)
    # Prefer a saved Learning category override when present.
    override = pref_store.lookup_classification(last_user)
    if override and override.get("category"):
        try:
            route_category = RouteCategory(override["category"])
        except ValueError:
            route_category = classification.primary
    else:
        route_category = classification.primary

    temperature = (
        req.temperature if req.temperature is not None else settings.aril_default_temperature
    )
    profile = resolve_profile(req.routing_profile)
    target_count = max(3, settings.aril_compare_model_count)

    if req.models:
        models = list(req.models)
    else:
        models = select_judge_models(
            last_user or " ",
            route_category,
            profile=profile,
            count=target_count,
        )

    # Deduplicate while preserving order; pad with capability peers if thin.
    seen: set[str] = set()
    models = [m for m in models if not (m in seen or seen.add(m))]
    if len(models) < target_count:
        for mid in select_judge_models(
            last_user or " ",
            route_category,
            profile=profile,
            count=target_count * 2,
        ):
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
        route_category=route_category,
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


@router.get("/store/status", response_model=StoreStatus)
async def store_status(check: bool = True) -> StoreStatus:
    """SQLite readiness, file path, and optional integrity probe."""
    return StoreStatus(**local_db.status(probe=check))


@router.post("/store/check", response_model=StoreStatus)
async def store_check() -> StoreStatus:
    """Force a SQLite connectivity / schema probe (Preferences → Database)."""
    return StoreStatus(**local_db.status(probe=True))


@router.get("/store/stats", response_model=StoreStats)
async def store_stats() -> StoreStats:
    counts = local_db.counts()
    return StoreStats(
        retention=local_db.get_retention(),
        counts=counts,
        total=sum(counts.values()),
    )


@router.patch("/store/retention", response_model=StoreStats)
async def store_retention_update(req: StoreRetentionUpdate) -> StoreStats:
    local_db.set_retention(req.retention)
    counts = local_db.counts()
    return StoreStats(
        retention=local_db.get_retention(),
        counts=counts,
        total=sum(counts.values()),
    )


@router.get("/store/records", response_model=list[StoreRecord])
async def store_records_list() -> list[StoreRecord]:
    return [StoreRecord(**row) for row in local_db.list_store_records()]


@router.delete("/store/records/{record_id}")
async def store_records_delete(record_id: str) -> dict:
    kind = local_db.delete_store_record(record_id)
    if not kind:
        raise HTTPException(status_code=404, detail="Record not found")
    return {"ok": True, "kind": kind}


@router.delete("/store/records", response_model=StoreDeleteAllResponse)
async def store_records_delete_all() -> StoreDeleteAllResponse:
    deleted = local_db.delete_all_store_records()
    return StoreDeleteAllResponse(ok=True, deleted=deleted)


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


@router.post("/settings/openrouter-key/check", response_model=OpenRouterConnectionStatus)
async def openrouter_key_check() -> OpenRouterConnectionStatus:
    """Validate the stored OpenRouter API key (Preferences → Check connection)."""
    return OpenRouterConnectionStatus(**await key_store.check_connection())


@router.post("/mcp/check", response_model=MCPCheckResponse)
async def mcp_check(req: MCPCheckRequest) -> MCPCheckResponse:
    """Probe a remote MCP server (initialize + tools/list). Does not invoke tools."""
    result = await check_remote_mcp(
        url=req.url,
        auth_style=req.auth_style,
        auth_header_name=req.auth_header_name,
        api_key=req.api_key,
    )
    return MCPCheckResponse(**result)


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


@router.get("/models/rankings/weekly", response_model=OpenRouterWeeklyRankingsResponse)
async def models_weekly_rankings(
    limit: int = 25, refresh: bool = False
) -> OpenRouterWeeklyRankingsResponse:
    """Top OpenRouter models by weekly token volume (`sort=top-weekly`)."""
    rows = list_weekly_rankings(limit=limit, force_refresh=refresh)
    return OpenRouterWeeklyRankingsResponse(
        models=rows,
        count=len(rows),
        period="top-weekly",
        refreshed=refresh,
        source="openrouter",
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
