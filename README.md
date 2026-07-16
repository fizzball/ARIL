# ARIL

**Adaptive Routing Intelligent Layer** — a macOS AI chat client with a local Solo gateway that grades prompts, classifies intent, suggests rewrites, and routes requests to the best model for accuracy, cost, tokens, and latency.

## Install (macOS 14+, Apple Silicon)

End users: download the DMG from [Releases](https://github.com/fizzball/ARIL/releases) — no Python or Xcode required. You need an [OpenRouter](https://openrouter.ai/keys) API key and a small credit balance.

**→ Full steps: [docs/INSTALL.md](docs/INSTALL.md)**

1. Download `ARIL-<version>.dmg`
2. Drag **ARIL** to Applications and open it
3. Preferences → General → paste your OpenRouter API key

## Develop

Contributors and local packaging: **[docs/DEVELOPING.md](docs/DEVELOPING.md)**

```bash
./scripts/dev-up.sh          # FastAPI on :8741
cd apps/macos && xcodegen generate && open ARIL.xcodeproj
./scripts/package-macos.sh   # build ARIL.app + DMG with embedded gateway
```

## Repository layout

```
ARIL/
├── apps/macos/           # SwiftUI native client
├── services/aril-api/    # FastAPI gateway + routing intelligence
├── scripts/              # Dev + packaging (gateway freeze, DMG)
├── docs/                 # Install / develop / ADRs
├── packages/schemas/     # Shared OpenAPI / JSON schemas
└── evals/                # Routing & grading benchmarks
```

## Status

Active solo-first product: Intelligence panel, Judge mode, Learning store, OpenRouter pricing, and Release packaging.

## License

[MIT](LICENSE)
