# ADR-006: OpenRouter as the multi-model gateway

## Status
Accepted

## Context
ARIL routes across Coding / Security / Cost / Performance / Confidence models from multiple upstream vendors. Maintaining separate SDKs and keys per vendor slows iteration.

## Decision
Use **OpenRouter** (`https://openrouter.ai/api/v1`) as the default chat dispatch layer:
- One `OPENROUTER_API_KEY` covers model switching
- Model IDs stay vendor-prefixed (`openai/gpt-4.1`, `anthropic/claude-sonnet-4`, …)
- Direct OpenAI / Anthropic / Ollama adapters remain optional fallbacks later
- Without a key, the stub provider keeps local UI/dev usable

## Consequences
- Simpler routing and cost attribution via OpenRouter usage
- Dependency on OpenRouter availability and model catalog naming
- Keys must never be committed; store only in gitignored `.env`
