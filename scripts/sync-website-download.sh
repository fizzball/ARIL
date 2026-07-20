#!/usr/bin/env bash
# Fetch the latest GitHub release DMG into website/downloads/ for aril.host.
#
# Usage:
#   ./scripts/sync-website-download.sh
#   ./scripts/sync-website-download.sh 0.4.6
#   ARIL_GITHUB_REPO=fizzball/ARIL ./scripts/sync-website-download.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS="$ROOT/website/downloads"
REPO="${ARIL_GITHUB_REPO:-fizzball/ARIL}"
VERSION="${1:-}"

mkdir -p "$DOWNLOADS"

if [[ -z "$VERSION" ]]; then
  echo "-> Resolving latest release for $REPO..."
  VERSION="$(gh release view --repo "$REPO" --json tagName -q '.tagName' | sed 's/^v//')"
fi

TAG="v${VERSION#v}"
DMG_NAME="ARIL-${VERSION#v}.dmg"
API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"

echo "-> Downloading ${TAG} (${DMG_NAME})..."
URL="$(API="$API" python3 - <<'PY'
import json, os, sys, urllib.request
api = os.environ["API"]
req = urllib.request.Request(api, headers={"Accept": "application/vnd.github+json", "User-Agent": "aril-website-sync"})
with urllib.request.urlopen(req) as resp:
    data = json.load(resp)
for asset in data.get("assets", []):
    if asset.get("name", "").endswith(".dmg"):
        print(asset["browser_download_url"])
        break
else:
    sys.exit("No DMG asset on release " + api)
PY
)"

TMP="$(mktemp)"
curl -fsSL "$URL" -o "$TMP"
SIZE="$(stat -f%z "$TMP" 2>/dev/null || stat -c%s "$TMP")"

cp "$TMP" "$DOWNLOADS/$DMG_NAME"
cp "$TMP" "$DOWNLOADS/ARIL-latest.dmg"
chmod 644 "$DOWNLOADS/$DMG_NAME" "$DOWNLOADS/ARIL-latest.dmg"
rm -f "$TMP"

PUBLISHED="$(gh release view "$TAG" --repo "$REPO" --json publishedAt -q '.publishedAt' 2>/dev/null | cut -c1-10 || true)"

cat > "$DOWNLOADS/latest.json" <<EOF
{
  "version": "${VERSION#v}",
  "file": "ARIL-latest.dmg",
  "published": "${PUBLISHED:-}",
  "size_bytes": ${SIZE},
  "requirements": "Apple Silicon Mac · macOS 14+ · OpenRouter key"
}
EOF

echo "-> Wrote $DOWNLOADS/$DMG_NAME (${SIZE} bytes)"
echo "-> Updated $DOWNLOADS/ARIL-latest.dmg and latest.json"
