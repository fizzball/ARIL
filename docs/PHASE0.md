# Phase 0 — Foundations

Goal: ship a runnable shell — Hermes-styled SwiftUI client + FastAPI gateway with stub routing preview — versioned on GitHub.

## Tickets

### P0-1 — Monorepo & private remote
- [x] Repo layout (`apps/`, `services/`, `docs/`, `evals/`, `packages/`)
- [x] ADRs for stack, API shape, routing pipeline
- [x] Private GitHub remote

### P0-2 — `aril-api` skeleton
- [x] FastAPI app with health + OpenAPI
- [x] `POST /v1/preview` stub (classify / grade / routes / estimates)
- [x] `POST /v1/chat` stub (echo / mock)
- [x] Provider adapter interface (stub + registry placeholders)
- [x] `.env.example`, requirements, basic tests

### P0-3 — macOS SwiftUI shell
- [x] XcodeGen project, noir theme tokens
- [x] `NavigationSplitView`: sidebar, empty hero, composite input bar, status footer
- [x] Settings stub (gateway URL, category→model map, temperature)
- [x] Wire health check + Intelligence Panel via preview API

### P0-4 — Shared schemas
- [x] OpenAPI-aligned JSON schema stub in `packages/schemas`
- [x] Client Codable models matching preview/chat contracts

### P0-5 — Dev UX
- [x] `scripts/dev-up.sh` to start API locally
- [x] Document how to open client against local gateway

## Exit criteria

1. `uvicorn` serves `/health` and `/v1/preview` with deterministic stub payloads
2. macOS app launches, shows ARIL empty state, lists sessions, calls preview on typing/send
3. ADRs merged; repo pushed to private GitHub

## Out of scope (Phase 0)

- Real provider calls / streaming tokens
- Prompt rewrite LLM
- Redis / Postgres production wiring
- Auth, multi-tenant quotas
- Multi-model compare execution

## Next (Phase 1)

- Streaming chat (SSE)
- Persist sessions to SwiftData / API
- Real OpenAI / Anthropic / Ollama adapters
- Sync RoutingProfile from Settings into preview scoring on the server
