# aril.host website

Static marketing site for ARIL, deployed to Hostinger at
`/home/u669814535/domains/aril.host/public_html`.

## Local preview

```bash
cd website
python3 -m http.server 8080
# open http://localhost:8080
```

## Sync latest DMG from GitHub

```bash
./scripts/sync-website-download.sh
```

Writes:

- `website/downloads/ARIL-<version>.dmg`
- `website/downloads/ARIL-latest.dmg` (stable download URL)
- `website/downloads/latest.json` (version badge)

## Deploy to Hostinger

```bash
# Optional: fetch latest release DMG first
./scripts/deploy-website.sh --sync-download
```

Set env vars if your host differs:

```bash
export HOSTINGER_SSH_HOST=145.79.25.220
export HOSTINGER_SSH_PORT=65002
export HOSTINGER_SSH_USER=u669814535
export HOSTINGER_WEB_ROOT=/home/u669814535/domains/aril.host/public_html
```

SSH access:

```bash
ssh -p 65002 u669814535@145.79.25.220
```

## Download URL

The site buttons point at:

```text
https://aril.host/downloads/ARIL-latest.dmg
```

This file is hosted on aril.host (not redirected to GitHub).

## CI

The Release workflow can deploy automatically when these GitHub secrets exist:

- `HOSTINGER_SSH_HOST`
- `HOSTINGER_SSH_PORT`
- `HOSTINGER_SSH_USER`
- `HOSTINGER_SSH_KEY` (private key, PEM)
- `HOSTINGER_WEB_ROOT` (optional)
