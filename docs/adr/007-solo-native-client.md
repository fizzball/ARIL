# ADR-007: Solo-mode native client (single-user)

## Status
Accepted (initial phases)

## Context
Multi-client server mode remains the long-term architecture, but early product validation is faster as a native macOS app used by one person.

## Decision
1. Default **Solo mode** in Settings: on launch, ARIL attempts to start a local `aril-api` on `127.0.0.1:8741` if one is not already healthy.
2. App sandbox is disabled for the solo/dev client so Process can spawn the local Python gateway.
3. Remote multi-client gateway remains supported by turning Solo mode off and pointing Gateway URL at a shared host.
4. Preference learning, sessions, and cache stay local to the solo gateway process/data dir.

## Consequences
- One-click local use without manually running `dev-up.sh` (when Python/venv is available)
- Distribution still requires Python + repo/`services/aril-api` until a later bundled runtime
- Packaging a fully self-contained .app (PyInstaller / embedded runtime) is a follow-up
