#!/usr/bin/env bash
# Build ARIL.app (Release), embed the Solo gateway, optionally wrap a DMG.
#
# Usage:
#   ./scripts/package-macos.sh
#   ./scripts/package-macos.sh --skip-gateway   # reuse dist/aril-gateway
#   ./scripts/package-macos.sh --keep-local-data  # do not wipe Application Support / key
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/package-macos.sh
#
# By default, packaging:
#   • never embeds sessions / judgements / .env / OpenRouter keys in the app or DMG
#   • purges this Mac's Application Support/ARIL + stored OpenRouter key so a
#     reinstall from the new package starts blank (override with --keep-local-data)
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
KEEP_LOCAL_DATA=0

# shellcheck source=package-cleanse.sh
source "$ROOT/scripts/package-cleanse.sh"
sanitize_build_env

for arg in "$@"; do
  case "$arg" in
    --skip-gateway) SKIP_GATEWAY=1 ;;
    --keep-local-data) KEEP_LOCAL_DATA=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
  esac
done

VERSION="$(grep -E 'MARKETING_VERSION:' "$MACOS/project.yml" | head -1 | awk '{print $2}' | tr -d '"')"
VERSION="${VERSION:-0.3.15}"

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
  cleanse_tree "$DIST/aril-gateway"
  verify_clean_tree "$DIST/aril-gateway" "dist/aril-gateway"
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

APP_TMP="$DIST/ARIL-tmp.app"
APP_CLEAN="$DIST/ARIL-clean.app"
rm -rf "$DIST/ARIL.app" "$APP_TMP" "$APP_CLEAN"
# ditto avoids AppleDouble / resource-fork detritus that breaks codesign.
ditto --norsrc --noextattr --noqtn "$APP_SRC" "$APP_TMP"

RESOURCES="$APP_TMP/Contents/Resources"
mkdir -p "$RESOURCES/aril-gateway"
ditto --norsrc --noextattr --noqtn "$DIST/aril-gateway" "$RESOURCES/aril-gateway"
chmod +x "$RESOURCES/aril-gateway/aril-gateway"
GATEWAY_BIN="$RESOURCES/aril-gateway/aril-gateway"
GATEWAY_DIR="$RESOURCES/aril-gateway"

# Never ship developer runtime data / secrets inside the app bundle.
cleanse_tree "$APP_TMP"
verify_clean_tree "$APP_TMP" "dist/ARIL.app"

# Strip remaining provenance / quarantine xattrs (macOS 15+).
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_TMP" 2>/dev/null || true
  find "$APP_TMP" -print0 | xargs -0 xattr -c 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$APP_TMP" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$APP_TMP" 2>/dev/null || true
fi
find "$APP_TMP" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

# Sign every nested Mach-O payload inside the embedded gateway before the launcher.
echo "-> Codesigning embedded gateway payloads (identity: ${SIGN_IDENTITY})..."
GATEWAY_DIR="$GATEWAY_DIR" SIGN_IDENTITY="$SIGN_IDENTITY" python3 - <<'PY'
import os
import subprocess
from pathlib import Path

gateway_dir = Path(os.environ["GATEWAY_DIR"])
sign_identity = os.environ["SIGN_IDENTITY"]

def is_macho(path: Path) -> bool:
    proc = subprocess.run(["file", str(path)], capture_output=True, text=True)
    return "Mach-O" in proc.stdout

targets = []
for path in gateway_dir.rglob("*"):
    if not path.is_file():
        continue
    if path == gateway_dir / "aril-gateway":
        continue
    if is_macho(path):
        targets.append(path)

for path in sorted(targets):
    if sign_identity == "-":
        cmd = ["codesign", "--force", "--sign", "-", str(path)]
    else:
        cmd = ["codesign", "--force", "--options", "runtime", "--sign", sign_identity, str(path)]
    subprocess.run(cmd, check=True)
PY

echo "-> Codesigning embedded gateway launcher (identity: ${SIGN_IDENTITY})..."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$GATEWAY_BIN"
else
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$GATEWAY_BIN"
fi

# macOS can reintroduce provenance metadata during nested signing; scrub once more
# before signing the outer app bundle or codesign rejects the bundle as detritus.
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_TMP" 2>/dev/null || true
  find "$APP_TMP" -print0 | xargs -0 xattr -c 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$APP_TMP" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$APP_TMP" 2>/dev/null || true
fi

# Re-copy into a fresh bundle after nested signing; on newer macOS builds this is
# more reliable than in-place xattr deletion for stripping provenance metadata.
ditto --norsrc --noextattr --noqtn "$APP_TMP" "$APP_CLEAN"
rm -rf "$APP_TMP"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_CLEAN" 2>/dev/null || true
  find "$APP_CLEAN" -print0 | xargs -0 xattr -c 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$APP_CLEAN" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$APP_CLEAN" 2>/dev/null || true
fi

echo "-> Codesigning app (identity: ${SIGN_IDENTITY})..."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_CLEAN"
else
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_CLEAN"
fi

codesign --verify --verbose=2 "$APP_CLEAN" || true

mv "$APP_CLEAN" "$DIST/ARIL.app"

# Remove superseded local DMGs when version bumps.
rm -f "$DIST"/ARIL-*.dmg 2>/dev/null || true

DMG="$DIST/ARIL-${VERSION}.dmg"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noqtn "$DIST/ARIL.app" "$STAGE/ARIL.app"
ln -sf /Applications "$STAGE/Applications"
cleanse_tree "$STAGE"
verify_clean_tree "$STAGE" "dmg-stage"

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

if [[ "$KEEP_LOCAL_DATA" -eq 0 ]]; then
  purge_local_install_data
else
  echo "-> Keeping local Application Support / OpenRouter key (--keep-local-data)"
fi

cat <<EOF

Packaged:
  $DIST/ARIL.app
  $DMG

Install: open the DMG, drag ARIL to Applications, launch, add OpenRouter key.
Local sessions / judgements / OpenRouter key were purged on this Mac unless you passed --keep-local-data.
EOF
