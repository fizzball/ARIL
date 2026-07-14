# ADR-002: FastAPI gateway as ARIL brain

## Status
Accepted

## Context
Routing requires classification, grading, optional rewrite, cost estimation, caching, and provider dispatch — shared across concurrent clients.

## Decision
Implement **`services/aril-api`** in **Python + FastAPI**:
- OpenAPI-first (`/v1/preview`, `/v1/chat`, `/v1/compare`, sessions later)
- Async provider adapters
- Local solo mode uses SQLite + in-memory/cache file; production uses Postgres + Redis
- macOS app talks HTTP/SSE to configurable base URL (default `http://127.0.0.1:8741`)

## Consequences
- Strong ecosystem for NLP/ML prototypes
- Dual-language repo (Swift + Python) — mitigated by OpenAPI/schemas package
- Single process can serve many clients from day one API shape
