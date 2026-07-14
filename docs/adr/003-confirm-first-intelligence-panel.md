# ADR-003: Pre-send Intelligence Panel & confirm-first routing

## Status
Accepted

## Context
Users need cost/quality transparency before spending tokens. Blind auto-routing erodes trust.

## Decision
1. **Preview before execute**: typing or explicit Preview triggers `POST /v1/preview` (prefer cheap/local classifier — not frontier models).
2. **Intelligence Panel** shows grade, alternatives, recommended route, token/cost estimate, cache badge.
3. **Confirm-first**: Auto mode still requires user confirm (or ⌘⏎) for Phase 1–3. Silent auto-send is a later opt-in.
4. Override always available: model, temperature, route mode (`auto` | `manual` | `compare`), cache toggle.

## Consequences
- Extra UI surface and debounce logic
- Preview path must be fast (<~500ms p95 for stub/heuristic) to feel live
- Higher trust and lower accidental spend
