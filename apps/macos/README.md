# ARIL macOS client

Native SwiftUI app. End-user installs: see **[docs/INSTALL.md](../../docs/INSTALL.md)**.

## Develop

```bash
# From repo root — API (optional if Solo will start monorepo gateway)
./scripts/dev-up.sh

cd apps/macos
xcodegen generate
open ARIL.xcodeproj
```

Default gateway URL: `http://127.0.0.1:8741`. Solo mode embeds/starts the local API.

## Package Release DMG

```bash
./scripts/package-macos.sh
```

See **[docs/DEVELOPING.md](../../docs/DEVELOPING.md)**.
