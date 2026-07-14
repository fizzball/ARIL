# ARIL

**Adaptive Routing Intelligent Layer** — a macOS AI chat client with a multi-client gateway that grades prompts, classifies intent, suggests rewrites, and routes requests to the best model for accuracy, cost, tokens, and latency.

## Vision

ARIL looks and feels like a premium native chat client (Hermes-inspired noir aesthetic). Before send, an **Intelligence Panel** shows:

- Prompt grade and alternative wordings
- Recommended model route (by category: Coding, Security, Cost, Performance, Confidence)
- Estimated tokens and cost
- Cache eligibility (>1024 tokens)

Users can accept the recommendation or override model, temperature, and route mode (Auto / Manual / Compare).

## Repository layout

```
ARIL/
├── apps/macos/           # SwiftUI native client
├── services/aril-api/    # FastAPI gateway + routing intelligence
├── packages/schemas/     # Shared OpenAPI / JSON schemas
├── docs/adr/             # Architecture Decision Records
├── docs/references/      # UI inspiration artefacts
├── evals/                # Routing & grading benchmarks
└── scripts/              # Dev helpers
```

## Locked decisions (Phase 0)

| Concern | Choice |
|---------|--------|
| Client | Native **SwiftUI** (macOS 14+) |
| Server | **Python FastAPI** |
| Storage | Postgres (prod) / SQLite (local solo) |
| Cache | Redis + provider-native prompt cache where available |
| First providers | OpenAI, Anthropic, Ollama (adapters) |
| Deploy mode | Local gateway first; same API for remote multi-client |

See [docs/adr/](docs/adr/) for full ADRs and [docs/PHASE0.md](docs/PHASE0.md) for tickets.

## Quick start

### API (local)

```bash
cd services/aril-api
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --reload --port 8741
```

Open http://127.0.0.1:8741/docs

### macOS client

```bash
cd apps/macos
xcodegen generate
open ARIL.xcodeproj
```

Set the gateway URL to `http://127.0.0.1:8741` in Settings (default).

## Status

Phase 0 scaffold — foundations only. Chat streaming, full Intelligence Panel, and production multi-tenant auth land in later phases.

## License

Private — all rights reserved.
