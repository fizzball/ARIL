# Developing ARIL

Contributor setup for the monorepo (Swift client + FastAPI gateway). End users should follow [INSTALL.md](INSTALL.md) and use GitHub Releases instead.

## Repository layout

```
ARIL/
├── apps/macos/            # SwiftUI client
├── services/aril-api/     # FastAPI Solo / multi-client gateway
├── scripts/               # Dev helpers + packaging
├── dist/                  # Package outputs (gitignored)
└── docs/                  # Install / develop / ADRs
```

## Prerequisites

- macOS 14+
- Xcode 15+ (or current stable)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Python 3.11+ (`python3`)

## Quick start (dev)

### 1. Gateway

```bash
./scripts/dev-up.sh
```

API: http://127.0.0.1:8741/docs

### 2. macOS client

```bash
cd apps/macos
xcodegen generate
open ARIL.xcodeproj
```

Run the **ARIL** scheme. With **Solo mode** on, the app tries to start the monorepo gateway (`.venv` + uvicorn `--reload` in Debug).

Or point Preferences → Gateway URL at an already running `dev-up.sh` instance and disable Solo if you prefer.

### 3. Tests

```bash
cd services/aril-api
source .venv/bin/activate
pytest -q
```

## Packaging a distributable app

Produces `dist/ARIL.app` and `dist/ARIL-<version>.dmg` with an **embedded** Solo gateway:

```bash
chmod +x scripts/package-gateway.sh scripts/package-macos.sh
./scripts/package-macos.sh
```

Options:

| Env / flag | Meaning |
|------------|---------|
| `--skip-gateway` | Reuse existing `dist/aril-gateway` |
| `SIGN_IDENTITY="Developer ID Application: …"` | Sign with your Developer ID |
| `NOTARIZE=1` + `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_PASSWORD` | Notarize DMG after build |

Ad-hoc signing (`SIGN_IDENTITY=-`, default) is fine for local smoke tests.

### What the package script does

1. Freeze `services/aril-api` with PyInstaller → `dist/aril-gateway/`
2. `xcodebuild` Release → temporary `ARIL.app`
3. Copy gateway into `ARIL.app/Contents/Resources/aril-gateway/`
4. Codesign and build a DMG via `hdiutil`

At runtime Solo mode prefers that bundled binary and writes data under  
`~/Library/Application Support/ARIL/` (`ARIL_DATA_DIR`).

## GitHub Releases

Pushing a tag `v*` runs [.github/workflows/release.yml](../.github/workflows/release.yml), which builds the DMG and attaches it to a Release.

```bash
git tag v0.3.6
git push origin v0.3.6
```

To notarize in CI later, add Apple secrets and set `NOTARIZE=1` / `SIGN_IDENTITY` in the workflow.

## Gateway path overrides

| Key | Purpose |
|-----|---------|
| UserDefaults `aril.apiRoot` | Force Solo to use a checkout path |
| Env `ARIL_DATA_DIR` | Writable data root (set automatically by the app) |
