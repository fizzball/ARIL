"""Thin wrapper around the local `semgrep` CLI with JSON -> text summarization."""

from __future__ import annotations

import asyncio
import json
import shutil
import tempfile
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from pathlib import Path


class SemgrepNotFoundError(RuntimeError):
    """Raised when the semgrep binary cannot be located."""


_INSTALL_HINT = (
    "semgrep is not installed or not on PATH. Install it with "
    "`brew install semgrep` (or `pipx install semgrep`) and try again."
)


@dataclass
class ScanPlan:
    """A prepared semgrep invocation plus any temp dir to clean up afterwards."""

    command: list[str]
    target_label: str
    cleanup_dirs: list[str] = field(default_factory=list)

    def cleanup(self) -> None:
        for d in self.cleanup_dirs:
            shutil.rmtree(d, ignore_errors=True)


@dataclass
class SemgrepScanner:
    semgrep_path: str = "semgrep"
    default_config: str = "auto"
    scan_timeout: int = 300

    def resolve_binary(self) -> str | None:
        """Return an executable semgrep path, searching PATH + common install dirs."""
        candidate = self.semgrep_path or "semgrep"
        found = shutil.which(candidate)
        if found:
            return found
        home = str(Path.home())
        for path in (
            "/opt/homebrew/bin/semgrep",
            "/usr/local/bin/semgrep",
            "/usr/bin/semgrep",
            f"{home}/.local/bin/semgrep",
        ):
            if shutil.which(path):
                return path
        return None

    def _base_binary(self) -> str:
        binary = self.resolve_binary()
        if not binary:
            raise SemgrepNotFoundError(_INSTALL_HINT)
        return binary

    def build_plan(
        self,
        kind: str,
        *,
        path: str | None = None,
        code: str | None = None,
        filename: str | None = None,
        rule: str | None = None,
        config: str | None = None,
    ) -> ScanPlan:
        """Build a semgrep command for an on-disk path or an inline code snippet.

        `kind` is one of: scan, security, custom.
        """
        binary = self._base_binary()
        cleanup_dirs: list[str] = []

        # Resolve the scan target: an existing path, or a temp dir holding `code`.
        target: str
        target_label: str
        clean_path = (path or "").strip()
        if clean_path:
            if not Path(clean_path).exists():
                raise ValueError(f"Path does not exist: {clean_path}")
            target = clean_path
            target_label = clean_path
        elif (code or "").strip():
            tmp_dir = tempfile.mkdtemp(prefix="aril-codescan-")
            cleanup_dirs.append(tmp_dir)
            safe_name = (filename or "snippet.txt").strip() or "snippet.txt"
            safe_name = Path(safe_name).name  # strip any path components
            file_path = Path(tmp_dir) / safe_name
            file_path.write_text(code or "", encoding="utf-8")
            target = str(file_path)
            target_label = safe_name
        else:
            raise ValueError("Provide either 'path' or 'code' to scan.")

        # Resolve the ruleset / config.
        if kind == "custom":
            rule_text = (rule or "").strip()
            if not rule_text:
                raise ValueError("A Semgrep rule (YAML) is required for a custom scan.")
            rule_dir = tempfile.mkdtemp(prefix="aril-codescan-rule-")
            cleanup_dirs.append(rule_dir)
            rule_path = Path(rule_dir) / "rule.yaml"
            rule_path.write_text(rule_text, encoding="utf-8")
            config_arg = str(rule_path)
        elif kind == "security":
            config_arg = "p/security-audit"
        else:  # scan
            config_arg = (config or "").strip() or self.default_config or "auto"

        command = [
            binary,
            "scan",
            "--json",
            "--metrics=off",
            "--disable-version-check",
            "--config",
            config_arg,
            target,
        ]
        return ScanPlan(command=command, target_label=target_label, cleanup_dirs=cleanup_dirs)

    async def run_streaming(
        self, command: list[str]
    ) -> AsyncIterator[tuple[str, str]]:
        """Run semgrep, yielding ('progress', line) as it scans then ('result', json).

        stderr carries semgrep's progress/log lines; stdout carries the `--json`
        report (drained concurrently to avoid pipe-buffer deadlock).
        """
        try:
            proc = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as exc:
            raise SemgrepNotFoundError(_INSTALL_HINT) from exc

        assert proc.stdout is not None and proc.stderr is not None
        stdout_task = asyncio.create_task(proc.stdout.read())
        err_tail: list[str] = []
        try:
            while True:
                try:
                    raw = await asyncio.wait_for(
                        proc.stderr.readline(), timeout=self.scan_timeout
                    )
                except asyncio.TimeoutError as exc:
                    proc.kill()
                    await proc.wait()
                    stdout_task.cancel()
                    raise RuntimeError(
                        f"semgrep scan timed out after {self.scan_timeout}s."
                    ) from exc
                if not raw:
                    break
                line = raw.decode("utf-8", errors="replace").strip()
                if line:
                    err_tail.append(line)
                    if len(err_tail) > 40:
                        err_tail.pop(0)
                    yield ("progress", line)
        finally:
            pass

        stdout = await stdout_task
        await proc.wait()
        out = stdout.decode("utf-8", errors="replace")
        # semgrep exits 1 when findings exist; only treat empty stdout as failure.
        if proc.returncode not in (0, 1) and not out.strip():
            tail = " ".join(err_tail[-3:]).strip()
            raise RuntimeError(f"semgrep failed: {tail or 'unknown error'}")
        yield ("result", out)

    def summarize(self, json_output: str) -> str:
        """Turn semgrep --json output into a compact, model-friendly text report."""
        raw = (json_output or "").strip()
        if not raw:
            return "No output from semgrep."
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return raw[:8000]

        results = data.get("results") or []
        errors = data.get("errors") or []
        paths = data.get("paths") or {}
        scanned = paths.get("scanned") or []

        lines: list[str] = []
        lines.append(
            f"Semgrep: {len(results)} finding(s) across {len(scanned)} scanned file(s)."
        )

        MAX_FINDINGS = 50
        for finding in results[:MAX_FINDINGS]:
            check_id = finding.get("check_id", "rule")
            fpath = finding.get("path", "?")
            start = finding.get("start") or {}
            line_no = start.get("line", "?")
            extra = finding.get("extra") or {}
            severity = str(extra.get("severity", "")).upper() or "INFO"
            message = (extra.get("message") or "").strip().replace("\n", " ")
            if len(message) > 300:
                message = message[:297] + "…"

            lines.append("")
            lines.append(f"[{severity}] {check_id}")
            lines.append(f"  {fpath}:{line_no} — {message}")

            metadata = extra.get("metadata") or {}
            tags: list[str] = []
            cwe = metadata.get("cwe")
            if isinstance(cwe, list) and cwe:
                tags.append("CWE: " + ", ".join(str(c) for c in cwe[:3]))
            elif isinstance(cwe, str) and cwe:
                tags.append(f"CWE: {cwe}")
            owasp = metadata.get("owasp")
            if isinstance(owasp, list) and owasp:
                tags.append("OWASP: " + ", ".join(str(o) for o in owasp[:2]))
            elif isinstance(owasp, str) and owasp:
                tags.append(f"OWASP: {owasp}")
            if tags:
                lines.append("    " + "  ".join(tags))

        if len(results) > MAX_FINDINGS:
            lines.append("")
            lines.append(f"… and {len(results) - MAX_FINDINGS} more finding(s).")

        if not results:
            lines.append("No findings.")

        if errors:
            lines.append("")
            lines.append(f"{len(errors)} scan error(s):")
            for err in errors[:5]:
                if isinstance(err, dict):
                    msg = (err.get("message") or err.get("type") or "error")
                    lines.append(f"  - {str(msg).strip()[:200]}")

        report = "\n".join(lines).strip()
        return report[:16000] if report else "No output from semgrep."
