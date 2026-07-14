"""ARIL API — Adaptive Routing Intelligent Layer gateway."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.routes import router
from app.core.config import settings

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


@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok",
        "service": "aril-api",
        "version": "0.1.0",
        "env": settings.aril_env,
        "gateway": "ready",
    }
