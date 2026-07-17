"""Self-contained Nmap MCP server (Streamable HTTP, JSON-RPC).

Runs as a managed subprocess launched by the ARIL macOS app. Reuses the
gateway's already-bundled FastAPI/uvicorn stack (no extra dependencies) so it
freezes into the same PyInstaller binary. Wraps the local `nmap` binary and
exposes it to MCP clients over an authenticated localhost endpoint.
"""

from app.nmap_mcp.config import NmapMCPConfig
from app.nmap_mcp.server import build_app, run

__all__ = ["NmapMCPConfig", "build_app", "run"]
