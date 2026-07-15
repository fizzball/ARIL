#!/usr/bin/env bash
# Build ARIL.app (Release), embed the Solo gateway, optionally wrap a DMG.
#
# Usage:
#   ./scripts/package-macos.sh
#   ./scripts/package-macos.sh --skip-gateway   # reuse dist/aril-gateway
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/package-macos.sh
#
# Outputs:
#   dist/ARIL.app
#   dist/ARIL-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$ROOT/apps/macos"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
SKIP_GATEWAY=0

for arg in "$@"; do
  case "$arg" in
    --skip-gateway) SKIP_GATEWAY=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
  esac
done

VERSION="$(grep -E 'MARKETING_VERSION:' "$MACOS/project.yml" | head -1 | awk '{print $2}' | tr -d '"')"
VERSION="${VERSION:-0.3.5}"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"

echo "-> Packaging ARIL ${VERSION}"

if [[ "$SKIP_GATEWAY" -eq 0 ]]; then
  "$ROOT/scripts/package-gateway.sh"
else
  if [[ ! -x "$DIST/aril-gateway/aril-gateway" ]]; then
    echo "error: dist/aril-gateway missing; run without --skip-gateway" >&2
    exit 1
  fi
fi

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$MACOS" && xcodegen generate)
fi

mkdir -p "$DIST" "$DERIVED"
echo "-> Building macOS Release..."
xcodebuild \
  -project "$MACOS/ARIL.xcodeproj" \
  -scheme ARIL \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_SRC="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name 'ARIL.app' | head -1)"
if [[ -z "$APP_SRC" || ! -d "$APP_SRC" ]]; then
  echo "error: ARIL.app not found under $DERIVED/Build/Products/Release" >&2
  exit 1
fi

rm -rf "$DIST/ARIL.app"
# ditto avoids AppleDouble / resource-fork detritus that breaks codesign.
ditto --norsrc --noextattr --noqtn "$APP_SRC" "$DIST/ARIL.app"

RESOURCES="$DIST/ARIL.app/Contents/Resources"
mkdir -p "$RESOURCES/aril-gateway"
ditto --norsrc --noextattr --noqtn "$DIST/aril-gateway" "$RESOURCES/aril-gateway"
chmod +x "$RESOURCES/aril-gateway/aril-gateway"

# Strip remaining provenance / quarantine xattrs (macOS 15+).
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$DIST/ARIL.app" 2>/dev/null || true
  find "$DIST/ARIL.app" -print0 | while IFS= read -r -d '' f; do
    xattr -c "$f" 2>/dev/null || true
  done
fi
find "$DIST/ARIL.app" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

echo "-> Codesigning app (identity: ${SIGN_IDENTITY})..."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$DIST/ARIL.app"
else
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$DIST/ARIL.app"
fi

codesign --verify --verbose=2 "$DIST/ARIL.app" || true

DMG="$DIST/ARIL-${VERSION}.dmg"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noqtn "$DIST/ARIL.app" "$STAGE/ARIL.app"
ln -sf /Applications "$STAGE/Applications"

echo "-> Creating ${DMG}..."
hdiutil create \
  -volname "ARIL ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"
rm -rf "$STAGE"

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_PASSWORD:-}" ]]; then
    echo "error: NOTARIZE=1 requires APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD" >&2
    exit 1
  fi
  echo "-> Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$DIST/ARIL.app"
fi

cat <<EOF

Packaged:
  $DIST/ARIL.app
  $DMG

Install: open the DMG, drag ARIL to Applications, launch, add OpenRouter key.
EOF
