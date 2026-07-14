# macOS client

Native SwiftUI shell for ARIL.

## Generate & open

```bash
cd apps/macos
xcodegen generate
open ARIL.xcodeproj
```

Select the **ARIL** scheme, run (⌘R). Ensure the API is up (`../../scripts/dev-up.sh`).

## Phase 0 features

- Hermes-inspired noir theme + ARIL empty hero
- Sidebar sessions, composite input bar, status footer
- Debounced Intelligence Panel via `POST /v1/preview`
- Settings: gateway URL + category→model maps + temperature
