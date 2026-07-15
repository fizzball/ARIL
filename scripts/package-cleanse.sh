#!/usr/bin/env bash
# Shared cleanse / verify helpers for ARIL packaging.
#
# Ensures dist never ships developer sessions, judgements, caches, or API keys.
# Optionally wipes this Mac's Application Support / ARIL runtime data so a
# freshly packaged install starts blank (use --keep-local-data to skip).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Files that must never appear under dist/ or inside ARIL.app.
SENSITIVE_GLOBS=(
  '.env'
  '.env.*'
  'aril.db'
  'aril.db-shm'
  'aril.db-wal'
  'sessions.json'
  'sessions-cache.json'
  'session_tombstones.json'
  'preferences.json'
  'prompt_cache.json'
)

# Unset secret env vars so freeze / xcodebuild cannot inherit them.
sanitize_build_env() {
  unset OPENROUTER_API_KEY 2>/dev/null || true
  unset ARIL_OPENROUTER_API_KEY 2>/dev/null || true
  export OPENROUTER_API_KEY=""
  # Prevent accidental write into the repo data dir during freeze imports.
  export ARIL_DATA_DIR="${ARIL_DATA_DIR_OVERRIDE:-/tmp/aril-package-empty-$$}"
  mkdir -p "$ARIL_DATA_DIR"
}

# Remove sensitive files if they somehow landed in a tree.
cleanse_tree() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  local name
  for name in "${SENSITIVE_GLOBS[@]}"; do
    find "$root" -type f -name "$name" -print -delete 2>/dev/null || true
  done
  # Accidental developer data copies next to the frozen gateway only.
  find "$root" \( -path '*/aril-gateway/data' -o -path '*/Contents/Resources/aril-gateway/data' \) \
    -type d -prune -exec rm -rf {} + 2>/dev/null || true
}

# Fail the build if any sensitive artifact remains under path.
verify_clean_tree() {
  local root="$1"
  local label="$2"
  [[ -d "$root" ]] || return 0
  local found=0
  local name hits
  for name in "${SENSITIVE_GLOBS[@]}"; do
    hits="$(find "$root" -type f -name "$name" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
      echo "error: sensitive file(s) present in ${label}:" >&2
      echo "$hits" >&2
      found=1
    fi
  done
  # Hex/text scan for common OpenRouter key prefix in small text-ish files only.
  if command -v rg >/dev/null 2>&1; then
    if rg -l --hidden -g '!.pyc' -g '!*.dylib' -g '!*.so' -g '!aril-gateway' \
        -g '!*.car' -g '!*.icns' -g '!*.png' \
        -e 'sk-or-v1-' -e 'OPENROUTER_API_KEY=' "$root" 2>/dev/null | head -20 | grep -q .; then
      echo "error: OpenRouter key material detected under ${label}" >&2
      rg -l --hidden -g '!.pyc' -g '!*.dylib' -g '!*.so' -g '!aril-gateway' \
        -g '!*.car' -g '!*.icns' -g '!*.png' \
        -e 'sk-or-v1-' -e 'OPENROUTER_API_KEY=' "$root" 2>/dev/null | head -20 >&2 || true
      found=1
    fi
  fi
  if [[ "$found" -ne 0 ]]; then
    exit 1
  fi
  echo "✓ ${label} cleanse verified"
}

# Wipe this Mac's packaged-app runtime state (not the git checkout).
purge_local_install_data() {
  local support="${HOME}/Library/Application Support/ARIL"
  if [[ -d "$support" ]]; then
    echo "→ Purging Application Support/ARIL (sessions, judgements, local .env)…"
    rm -rf "$support"
  fi

  # Sandboxed container copy (if any).
  local container_support="${HOME}/Library/Containers/com.aril.app/Data/Library/Application Support/ARIL"
  if [[ -d "$container_support" ]]; then
    echo "→ Purging Containers/…/Application Support/ARIL…"
    rm -rf "$container_support"
  fi

  _clear_defaults_key() {
    local domain="$1"
    local key="$2"
    defaults delete "$domain" "$key" 2>/dev/null || true
  }

  echo "→ Clearing OpenRouter key and session defaults (com.aril.app)…"
  # Standard domain + explicit plist paths (sandbox vs non-sandbox).
  for domain in \
    "com.aril.app" \
    "${HOME}/Library/Preferences/com.aril.app" \
    "${HOME}/Library/Containers/com.aril.app/Data/Library/Preferences/com.aril.app"
  do
    _clear_defaults_key "$domain" "aril.openRouterAPIKey"
    _clear_defaults_key "$domain" "aril.deletedSessionIDs"
    _clear_defaults_key "$domain" "openRouterAPIKey"
  done

  # Belt-and-suspenders for the on-disk plist.
  local plist="${HOME}/Library/Preferences/com.aril.app.plist"
  if [[ -f "$plist" ]] && command -v plutil >/dev/null 2>&1; then
    plutil -remove aril.openRouterAPIKey "$plist" 2>/dev/null || true
    plutil -remove aril.deletedSessionIDs "$plist" 2>/dev/null || true
  fi

  # Dev gateway data beside the repo must not be mistaken as "bundled" data,
  # but we do not delete the developer's checkout data unless asked via
  # PURGE_REPO_DATA=1 (keeps local uvicorn history intact by default).
  if [[ "${PURGE_REPO_DATA:-0}" == "1" ]]; then
    echo "→ Purging services/aril-api/data (PURGE_REPO_DATA=1)…"
    rm -rf "$ROOT/services/aril-api/data"
    mkdir -p "$ROOT/services/aril-api/data"
    if [[ -f "$ROOT/services/aril-api/.env" ]]; then
      echo "→ Removing services/aril-api/.env (PURGE_REPO_DATA=1)…"
      rm -f "$ROOT/services/aril-api/.env"
    fi
  fi
}
