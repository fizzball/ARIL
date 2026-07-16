# Install ARIL (end users)

ARIL is a native **macOS 14+** chat client. Solo mode runs a bundled local gateway inside the app — you do **not** need to install Python, Xcode, or run terminal scripts.

## Requirements

- **Apple Silicon Mac** (M-series) with **macOS 14** (Sonoma) or newer
- An [OpenRouter](https://openrouter.ai/keys) API key (`sk-or-v1-…`) with a small credit balance — add a few dollars at [openrouter.ai](https://openrouter.ai) before your first chat

## Install from GitHub Releases

1. Open the latest release: [github.com/fizzball/ARIL/releases](https://github.com/fizzball/ARIL/releases)
2. Download **`ARIL-<version>.dmg`**
3. Open the DMG and drag **ARIL** into **Applications**
4. Launch **ARIL** from Applications (or Spotlight)
5. Open **ARIL → Preferences → General**
6. Paste your OpenRouter API key and save
7. Keep **Solo mode** enabled (default) so the local gateway starts automatically

### Gatekeeper / “app can’t be opened”

Release builds from CI may be **ad-hoc signed** until Developer ID notarization is configured.

If macOS blocks the app:

1. Right-click **ARIL** → **Open** → **Open**
2. Or: **System Settings → Privacy & Security** → allow the blocked app

Notarized builds (when published) open without this step.

## Using ARIL

- Type a prompt — the Intelligence panel analyses and recommends a model
- **Auto** routes for you; **Manual** locks your model pick; **Judge** compares three capability-matched models
- Learning judgements are stored locally under  
  `~/Library/Application Support/ARIL/`

## Uninstall

1. Quit ARIL  
2. Move **ARIL.app** from Applications to Trash  
3. Optional: delete `~/Library/Application Support/ARIL/` to remove local history and Learning data  

## Packaging (developers)

`./scripts/package-macos.sh` builds a clean DMG: it never embeds sessions, judgements, or OpenRouter keys. By default it also **purges this Mac’s** `~/Library/Application Support/ARIL/` and the stored OpenRouter key so reinstalling the new build starts blank. Pass `--keep-local-data` to keep your local history while packaging.

## Troubleshooting

| Symptom | What to try |
|--------|-------------|
| “Gateway offline” / “Starting gateway…” | Wait a few seconds; check Preferences Solo message; relaunch ARIL |
| “API key required” | Preferences → General → set OpenRouter key |
| Port 8741 in use | Quit other ARIL/gateway processes; relaunch |
| Empty chat after reinstall | History lives in Application Support — restore that folder if you backed it up |

## Build from source

See [DEVELOPING.md](DEVELOPING.md) if you want to contribute or package locally.
