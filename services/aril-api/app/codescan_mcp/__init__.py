"""Self-contained Semgrep code-scan MCP server (Streamable HTTP, JSON-RPC).

Runs as a managed subprocess launched by the ARIL macOS app. Reuses the
gateway's already-bundled FastAPI/uvicorn stack (no extra dependencies) so it
freezes into the same PyInstaller binary. Wraps the local `semgrep` binary and
exposes it to MCP clients over an authenticated localhost endpoint.
"""

from app.codescan_mcp.config import CodeScanMCPConfig
from app.codescan_mcp.server import build_app, run

__all__ = ["CodeScanMCPConfig", "build_app", "run"]
