# Phase 2 — Intelligence depth

## Done

- [x] LLM-assisted prompt alternatives (`enhance_alternatives` on preview)
- [x] Multi-model compare (`POST /v1/compare` + Compare mode UI)
- [x] Completion cache for prompts over 1024 tokens (file-backed)
- [x] Cache hit surfaced in preview + footer

## Try

1. Weak short prompt → Intelligence panel shows **LLM** alternatives
2. Switch mode to **Compare** → send → side-by-side model cards
3. Long prompt (>1024 tokens est.) twice → second call should show cache hit

## Later

- Redis/Postgres for multi-instance cache + sessions
- Provider-native prompt caching headers
- Auth / multi-tenant quotas
- Offline eval harness for routing quality
