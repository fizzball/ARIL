# Shared schemas

Canonical HTTP contract for ARIL clients and the gateway.

- `openapi.json` — Preview / Chat / Health operations (expand as phases land)
- Prefer generating typed clients from this file in later phases

Server Pydantic models in `services/aril-api/app/core/schemas.py` are the implementation source of truth for Phase 0; keep OpenAPI in sync when changing request/response shapes.
