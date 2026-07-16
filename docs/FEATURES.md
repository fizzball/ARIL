# ARIL features

High-level capabilities of the Adaptive Routing Intelligent Layer macOS client.

## macOS native AI chat client

SwiftUI app with multi-session chat history (create/delete sessions, sidebar session list).

## Local “Solo” gateway

Can auto-start an embedded local FastAPI gateway (default `http://127.0.0.1:8741`) so the app works as a self-contained product.

## OpenRouter integration

Uses an OpenRouter API key to access live models; includes in-app key management plus “check connection” and credit/status display.

## Adaptive routing (Auto / Manual / Compare)

- **Auto** — Classifies the prompt into a capability/category and selects the mapped best model. When you have **Prefer** history, Auto promotes that winner: fingerprint match first, then category wins (e.g. “Because you preferred openai/gpt-4.1 for Coding”). Auto-seeded Learning judgements do not count as Prefer wins.
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
- **Prefer** wins (Judge or explicit Prefer) feed Auto routing and appear in the Intelligence panel as a short preference reason.
- **Category Prefer wins** table in the Learning panel (from preferences snapshot).
- **Run Auto eval** — fixed ~8 smoke prompts through Auto; results append to an in-Learning eval log (prompt, model, cost, ok/fail). Full Auto vs Manual vs Judge bake-off is deferred.

## Cost & pricing visibility

- Shows model pricing (USD / 1K tokens) in Preferences / Other… and reply footers, pulling from OpenRouter when available with built-in fallbacks.
- Tracks per-message actual cost and session total cost (and shows whether a response was cached).
- **Toolbar → Model popularity** flyout: OpenRouter weekly token rankings (`top-weekly`); tap a row to lock it in Manual mode. (Replaces the old Model costs flyout.)
- **Budget guardrails** (Preferences → General → Budget): master **Enable budget guardrails** toggle (off by default). Session/Daily Soft/Hard USD caps in a grid ($0.50 stepper steps; `0` = off for that cap). Soft caps confirm before send; hard caps block. Judge, web search, and image-gen always soft-confirm when a soft cap is set. Daily spend is tracked by local calendar date even when guardrails are off.

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
- **Other… catalog:** Vision filter uses OpenRouter `input_modalities` when present (requires `image`), with the previous name-heuristic fallback when modalities are missing; empty Vision results show a clear empty state
- **Other… Weekly popular:** callout panel ranked by OpenRouter weekly token volume (`sort=top-weekly`); tap a row to select
- Temperature defaults + per-session slider
- Appearance themes and user display name
- Gateway + database status pages and checks
- Log Analysis tab in Preferences
- Budget soft/hard caps (see Cost & pricing)

## MCP (Preferences + chat tools)

Configure remote MCP servers in **Preferences → MCP**:

- Built-in presets (disabled by default): Agenty, AI Diagram Maker, Cloudflare Browser, DeepWiki, GitHub, Firecrawl
- Selective enable per server + master **Use MCP servers** toggle
- API keys stored in Keychain; **Check connection** probes initialize + tools/list via the Solo gateway
- **Add server…** for custom remote HTTP endpoints
- **Playwright** is listed as deferred (local stdio / Node required later)
- **Chat (Auto / Manual):** ready enabled servers are attached each turn; the Solo gateway lists tools, runs OpenRouter tool calls, and shows brief status in the assistant bubble (`Using DeepWiki · ask_question…`)
- **Judge / Compare** does not use MCP tools
