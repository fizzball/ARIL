#!/usr/bin/env python3
"""Frozen Solo gateway entrypoint (PyInstaller).

Launch uvicorn with the FastAPI app object (not a string import) so the
freeze includes the application package reliably.
"""

from __future__ import annotations

import os
import sys


def main() -> None:
    # Allow resource extraction folder to be found when frozen.
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        os.environ.setdefault("ARIL_FROZEN", "1")

    # Pydantic on Python 3.9 needs this to evaluate `X | Y` annotations.
    try:
        import eval_type_backport  # noqa: F401
    except ImportError:
        pass

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
