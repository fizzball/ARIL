"""Config loading for the managed Semgrep code-scanning MCP server.

The ARIL app writes this file (host pinned to 127.0.0.1 + a generated bearer
token) before launching the server, so the token in the app's Keychain and the
token the server enforces can never drift. Standalone/manual users can point
`--config` at their own file; a missing token is generated and persisted.
"""

from __future__ import annotations

import json
import secrets
from dataclasses import dataclass
from pathlib import Path


def generate_token() -> str:
    return secrets.token_urlsafe(32)


@dataclass
class CodeScanMCPConfig:
    host: str = "127.0.0.1"
    port: int = 8743
    path: str = "/mcp"
    token: str = ""
    semgrep_path: str = "semgrep"
    # Default Semgrep ruleset passed to `--config` (registry `auto` needs network).
    default_config: str = "auto"
    # Per-scan wall-clock cap (seconds) before the scan is killed.
    scan_timeout: int = 300

    @property
    def normalized_path(self) -> str:
        p = (self.path or "/mcp").strip()
        if not p.startswith("/"):
            p = "/" + p
        return p.rstrip("/") or "/mcp"

    @classmethod
    def load(cls, config_path: str | Path | None) -> "CodeScanMCPConfig":
        """Load config from JSON, generating+persisting a token if absent."""
        if not config_path:
            cfg = cls()
            cfg.token = generate_token()
            return cfg

        path = Path(config_path)
        if not path.exists():
            cfg = cls()
            cfg.token = generate_token()
            cfg.save(path)
            return cfg

        data = json.loads(path.read_text(encoding="utf-8"))
        cfg = cls(
            host=str(data.get("host", "127.0.0.1")),
            port=int(data.get("port", 8743)),
            path=str(data.get("path", "/mcp")),
            token=str(data.get("token", "")),
            semgrep_path=str(data.get("semgrep_path", "semgrep")),
            default_config=str(data.get("default_config", "auto")),
            scan_timeout=int(data.get("scan_timeout", 300)),
        )
        if not cfg.token:
            cfg.token = generate_token()
            cfg.save(path)
        return cfg

    def save(self, config_path: str | Path) -> None:
        path = Path(config_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "host": self.host,
            "port": self.port,
            "path": self.path,
            "token": self.token,
            "semgrep_path": self.semgrep_path,
            "default_config": self.default_config,
            "scan_timeout": self.scan_timeout,
        }
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
