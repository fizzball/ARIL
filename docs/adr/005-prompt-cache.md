# ADR-005: Prompt cache for large prompts

## Status
Accepted

## Context
Prompts >1024 tokens are expensive to repeat. Providers offer native prompt caching; we also want gateway-level reuse.

## Decision
- Eligibility: estimated input tokens **> 1024**
- Cache key: hash(normalized prompt + system + model family + temperature bucket + critical params)
- Prefer **provider-native** caching when available; fall back to Redis/blob completion cache for identical requests
- Surface hit/miss and estimated savings on the Intelligence Panel

## Consequences
- Privacy/retention settings mandatory before enabling shared remote cache
- Normalization must not strip semantically material whitespace in code blocks
