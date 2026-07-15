#!/usr/bin/env bash
# Build a frozen Solo gateway (PyInstaller onedir) into dist/aril-gateway/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="$ROOT/services/aril-api"
OUT="$ROOT/dist/aril-gateway"
WORK="$ROOT/build/pyinstaller"

# shellcheck source=package-cleanse.sh
source "$ROOT/scripts/package-cleanse.sh"
sanitize_build_env

cd "$API"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

python -m pip install -q --upgrade pip
python -m pip install -q -r requirements.txt
python -m pip install -q "pyinstaller>=6.3"

mkdir -p "$ROOT/dist" "$WORK"
rm -rf "$OUT" "$WORK/aril-gateway"

echo "→ Freezing Solo gateway (PyInstaller)…"
# Do not freeze with a developer .env beside the cwd — temporarily hide it.
ENV_BACKUP=""
if [[ -f "$API/.env" ]]; then
  ENV_BACKUP="$API/.env.package-hide"
  mv "$API/.env" "$ENV_BACKUP"
fi
restore_env() {
  if [[ -n "${ENV_BACKUP}" && -f "${ENV_BACKUP}" ]]; then
    mv "${ENV_BACKUP}" "$API/.env"
  fi
}
trap restore_env EXIT

pyinstaller \
  --noconfirm \
  --clean \
  --distpath "$ROOT/dist" \
  --workpath "$WORK" \
  packaging/aril-gateway.spec

restore_env
trap - EXIT

# Spec COLLECT name is aril-gateway under dist/
if [[ ! -x "$OUT/aril-gateway" ]]; then
  echo "error: expected executable at $OUT/aril-gateway" >&2
  exit 1
fi

cleanse_tree "$OUT"
verify_clean_tree "$OUT" "dist/aril-gateway"

# Keep console quiet for GUI launch; allow manual smoke test:
#   ARIL_DATA_DIR=/tmp/aril-smoke ./dist/aril-gateway/aril-gateway
chmod +x "$OUT/aril-gateway"
echo "✓ Gateway ready: $OUT"
