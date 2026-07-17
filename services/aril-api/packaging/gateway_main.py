#!/usr/bin/env python3
"""Frozen Solo gateway entrypoint (PyInstaller).

Launch uvicorn with the FastAPI app object (not a string import) so the
freeze includes the application package reliably.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# When run as a plain script (not frozen / not `-m`), ensure the API root is on
# sys.path so `import app...` resolves. PyInstaller sets this via pathex already.
_API_ROOT = Path(__file__).resolve().parent.parent
if str(_API_ROOT) not in sys.path:
    sys.path.insert(0, str(_API_ROOT))


def _run_nmap_mcp(argv: list[str]) -> None:
    """Dispatch `aril-gateway nmap-mcp --config <path>` to the managed scanner."""
    import argparse

    parser = argparse.ArgumentParser(prog="aril-gateway nmap-mcp")
    parser.add_argument("-c", "--config", default=None, help="Path to config.json")
    args = parser.parse_args(argv)

    from app.nmap_mcp.server import run as run_nmap

    run_nmap(args.config)


def _run_code_mcp(argv: list[str]) -> None:
    """Dispatch `aril-gateway code-mcp --config <path>` to the managed code scanner."""
    import argparse

    parser = argparse.ArgumentParser(prog="aril-gateway code-mcp")
    parser.add_argument("-c", "--config", default=None, help="Path to config.json")
    args = parser.parse_args(argv)

    from app.codescan_mcp.server import run as run_code

    run_code(args.config)


def main() -> None:
    # Allow resource extraction folder to be found when frozen.
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        os.environ.setdefault("ARIL_FROZEN", "1")

    # Pydantic on Python 3.9 needs this to evaluate `X | Y` annotations.
    try:
        import eval_type_backport  # noqa: F401
    except ImportError:
        pass

    # Subcommand dispatch: the same frozen binary also serves the managed MCP servers.
    if len(sys.argv) > 1 and sys.argv[1] == "nmap-mcp":
        _run_nmap_mcp(sys.argv[2:])
        return
    if len(sys.argv) > 1 and sys.argv[1] == "code-mcp":
        _run_code_mcp(sys.argv[2:])
        return

    host = os.environ.get("ARIL_HOST", "127.0.0.1")
    port = int(os.environ.get("ARIL_PORT", "8741"))
    log_level = os.environ.get("ARIL_LOG_LEVEL", "info")

    # Ensure Application Support / ARIL_DATA_DIR is honoured before imports
    # that open SQLite on first request.
    from app.main import app
    import uvicorn

    uvicorn.run(
        app,
        host=host,
        port=port,
        log_level=log_level,
        factory=False,
    )


if __name__ == "__main__":
    main()
