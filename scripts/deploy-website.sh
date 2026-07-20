#!/usr/bin/env bash
# Deploy website/ to Hostinger public_html for aril.host.
#
# Usage:
#   ./scripts/deploy-website.sh
#   ./scripts/deploy-website.sh --sync-download   # fetch latest DMG first
#
# Environment (or pass via shell):
#   HOSTINGER_SSH_HOST=145.79.25.220
#   HOSTINGER_SSH_PORT=65002
#   HOSTINGER_SSH_USER=u669814535
#   HOSTINGER_WEB_ROOT=/home/u669814535/domains/aril.host/public_html
#
# Requires SSH key auth or an unlocked agent. Password auth is interactive only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/website"
SYNC_DOWNLOAD=0

for arg in "$@"; do
  case "$arg" in
    --sync-download) SYNC_DOWNLOAD=1 ;;
  esac
done

HOST="${HOSTINGER_SSH_HOST:-145.79.25.220}"
PORT="${HOSTINGER_SSH_PORT:-65002}"
USER="${HOSTINGER_SSH_USER:-u669814535}"
REMOTE="${HOSTINGER_WEB_ROOT:-/home/u669814535/domains/aril.host/public_html}"

if [[ "$SYNC_DOWNLOAD" -eq 1 ]]; then
  "$ROOT/scripts/sync-website-download.sh"
fi

if [[ ! -f "$WEB/index.html" ]]; then
  echo "error: $WEB/index.html missing" >&2
  exit 1
fi

echo "-> Deploying website to ${USER}@${HOST}:${REMOTE} (port ${PORT})..."

RSYNC_SSH="ssh -p ${PORT} -o StrictHostKeyChecking=accept-new"

rsync -avz --delete --chmod=D755,F644 \
  -e "$RSYNC_SSH" \
  "$WEB/" \
  "${USER}@${HOST}:${REMOTE}/"

echo "-> Done. Site: https://aril.host/"
