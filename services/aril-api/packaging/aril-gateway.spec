# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the Solo gateway binary."""

from pathlib import Path

from PyInstaller.utils.hooks import collect_all, collect_submodules

ROOT = Path(SPECPATH).resolve().parent
APP = ROOT / "app"
ENTRY = ROOT / "packaging" / "gateway_main.py"

datas = []
binaries = []
hiddenimports = collect_submodules("app")

for pkg in ("uvicorn", "fastapi", "starlette", "pydantic", "pydantic_settings", "httpx", "anyio"):
    try:
        d, b, h = collect_all(pkg)
        datas += d
        binaries += b
        hiddenimports += h
    except Exception:
        pass

a = Analysis(
    [str(ENTRY)],
    pathex=[str(ROOT)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports
    + [
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.websockets",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.lifespan",
        "uvicorn.lifespan.on",
        "app.main",
        "app.api.routes",
        "app.nmap_mcp",
        "app.nmap_mcp.server",
        "app.nmap_mcp.scanner",
        "app.nmap_mcp.config",
        "app.codescan_mcp",
        "app.codescan_mcp.server",
        "app.codescan_mcp.scanner",
        "app.codescan_mcp.config",
        "defusedxml",
        "defusedxml.ElementTree",
        "defusedxml.common",
        "multipart",
        "eval_type_backport",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["pytest", "tkinter"],
    noarchive=False,
    optimize=0,
)

# Never ship developer SQLite / sessions / .env if they were collected via datas.
_BLOCK = {
    ".env",
    "aril.db",
    "aril.db-shm",
    "aril.db-wal",
    "sessions.json",
    "sessions-cache.json",
    "session_tombstones.json",
    "preferences.json",
    "prompt_cache.json",
}


def _is_blocked(entry) -> bool:
    # TOC entry: (dest_name, src_path, typecode)
    name = str(entry[0]).replace("\\", "/")
    base = name.rsplit("/", 1)[-1]
    if base in _BLOCK or base.startswith(".env"):
        return True
    if "/data/" in f"/{name}" and base.endswith((".json", ".db", "-wal", "-shm")):
        return True
    return False


a.datas = [e for e in a.datas if not _is_blocked(e)]

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="aril-gateway",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="aril-gateway",
)
