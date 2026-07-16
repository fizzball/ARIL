# ARIL features

High-level capabilities of the Adaptive Routing Intelligent Layer macOS client.

## macOS native AI chat client

SwiftUI app with multi-session chat history (create/delete sessions, sidebar session list).

## Local “Solo” gateway

Can auto-start an embedded local FastAPI gateway (default `http://127.0.0.1:8741`) so the app works as a self-contained product.

## OpenRouter integration

Uses an OpenRouter API key to access live models; includes in-app key management plus “check connection” and credit/status display.

## Adaptive routing (Auto / Manual / Compare)

- **Auto** — Classifies the prompt into a capability/category and selects the mapped best model.
- **Manual** — Locks the model you chose (no auto swapping).
- **Compare (“Judge” mode)** — Runs the same prompt across ~3 capability-matched models, ranks them with an Equivalence Score (ES), and lets you Prefer a winner.

## Prompt intelligence panel

Runs after an idle delay while you type:

- Classification (category + fit/confidence)
- Prompt “grade” (quality score, not factual correctness)
- Token estimate, estimated cost, and latency/probe
- Prompt rewrite alternatives (heuristic + optional LLM-generated alternatives when quality is low)
- Routing analysis view (“why this model was picked”, confidence index)

## Learning / feedback loop (“Learning” store)

- Stores judgements/classifications, analysis cache snapshots, and chat transactions in a local SQLite store.
- Browse/filter records, edit/remove classifications, set retention, and clear records.
- Can skip re-analysis when a matching judgement exists (token saver), with “Redo Analysis” to refresh.

## Cost & pricing visibility

- Shows model pricing (USD / 1K tokens), pulling from OpenRouter when available with built-in fallbacks.
- Tracks per-message actual cost and session total cost (and shows whether a response was cached).

## Prompt/result caching

Gateway-side prompt cache for eligible prompts; cached replies are marked and discounted in cost reporting.

## Attachments + multimodal awareness

UI supports attaching images/files (size-capped), and the gateway avoids caching for web-search/attachments/image-gen turns.

## Optional web search flag

Requests can be sent with web-search enabled (with cost implications surfaced in the intelligence UI).

## System metrics in the title bar

Live system metrics monitor displayed in the main toolbar.

## Preferences & customization

- Global system prompt option injected into every request when enabled + token estimate + save/restore defaults
- Model mapping per category (and browse full OpenRouter catalog)
- Temperature defaults + per-session slider
- Appearance themes and user display name
- Gateway + database status pages and checks
- Log Analysis tab in Preferences

## MCP (planned/backlog)

UI has an MCP section, but configuration is not complete yet.
