# Phase 1 — Live chat, streaming, sessions, routing sync

## Done

- [x] Live OpenRouter chat (`POST /v1/chat`)
- [x] SSE streaming (`POST /v1/chat/stream`) + macOS consumer
- [x] Session persist API (`GET/PUT/DELETE /v1/sessions`) with JSON file store
- [x] Client loads/saves session history from gateway
- [x] Settings `RoutingProfile` sent on preview/chat; scorer honors maps
- [x] Health reports `chat_provider` / OpenRouter configured

## Still later

- Redis/Postgres multi-instance session backing
- Prompt rewrite LLM (not heuristic)
- Multi-model compare execution
- Provider-native prompt caching integration
- Auth / multi-tenant quotas
