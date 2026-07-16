"""ARIL API — Adaptive Routing Intelligent Layer gateway."""

from __future__ import annotations

import logging
import traceback

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.routes import router
from app.core.config import settings

logger = logging.getLogger("aril-api")

app = FastAPI(
    title="ARIL API",
    description="Adaptive Routing Intelligent Layer — preview, route, and dispatch LLM requests.",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Surface a concise reason so Solo clients are not stuck with a bare 500."""
    # Let FastAPI's own handlers deal with expected HTTP / validation failures.
    if isinstance(exc, (HTTPException, RequestValidationError)):
        raise exc
    logger.error("Unhandled error on %s %s\n%s", request.method, request.url.path, traceback.format_exc())
    detail = str(exc).strip() or exc.__class__.__name__
    if len(detail) > 400:
        detail = detail[:397] + "…"
    return JSONResponse(status_code=500, content={"detail": detail})


@app.get("/health")
async def health() -> dict:
    openrouter = bool(settings.openrouter_api_key.strip())
    return {
        "status": "ok",
        "service": "aril-api",
        "version": "0.1.0",
        "env": settings.aril_env,
        "gateway": "ready",
        "chat_provider": "openrouter" if openrouter else "stub",
        "openrouter_configured": openrouter,
    }
