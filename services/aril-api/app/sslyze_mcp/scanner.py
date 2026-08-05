"""Thin wrapper around the local `sslyze` CLI with JSON -> text summarization."""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import tempfile
from collections.abc import AsyncIterator
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse


class SSLyzeNotFoundError(RuntimeError):
    """Raised when the sslyze binary cannot be located."""


_INSTALL_HINT = (
    "sslyze is not installed or not on PATH. Install it with "
    "`brew install pipx && pipx install sslyze`, then try again."
)

# Reject shell metacharacters in custom extra flags.
_UNSAFE_ARGS = re.compile(r"[;&|`$<>\n\r]")


@dataclass
class ScanPlan:
    command: list[str]
    target_label: str
    json_out_path: str | None = None


@dataclass
class SSLyzeScanner:
    sslyze_path: str = "sslyze"
    scan_timeout: int = 180

    def resolve_binary(self) -> str | None:
        """Return an executable sslyze path, searching PATH + common install dirs."""
        candidate = self.sslyze_path or "sslyze"
        found = shutil.which(candidate)
        if found:
            return found
        home = str(Path.home())
        for path in (
            "/opt/homebrew/bin/sslyze",
            "/usr/local/bin/sslyze",
            "/usr/bin/sslyze",
            f"{home}/.local/bin/sslyze",
            f"{home}/.local/pipx/venvs/sslyze/bin/sslyze",
        ):
            if Path(path).is_file() and os.access(path, os.X_OK):
                return path
            found = shutil.which(path)
            if found:
                return found
        return None

    def _base_binary(self) -> str:
        binary = self.resolve_binary()
        if not binary:
            raise SSLyzeNotFoundError(_INSTALL_HINT)
        return binary

    def normalize_target(self, target: str) -> str:
        """Accept host, host:port, or https://host[/path] → host:port for sslyze."""
        raw = (target or "").strip()
        if not raw:
            raise ValueError("A target hostname or URL is required.")
        if _UNSAFE_ARGS.search(raw):
            raise ValueError("Target contains unsafe characters.")

        host = raw
        port: int | None = None

        if "://" in raw:
            parsed = urlparse(raw if "://" in raw else f"https://{raw}")
            host = (parsed.hostname or "").strip()
            if not host:
                raise ValueError(f"Could not parse hostname from: {raw}")
            if parsed.port:
                port = parsed.port
            elif parsed.scheme in ("https", "wss"):
                port = 443
            elif parsed.scheme in ("http", "ws"):
                port = 80
        elif raw.count(":") == 1 and not raw.startswith("["):
            # host:port (simple IPv4 / hostname)
            left, right = raw.rsplit(":", 1)
            if right.isdigit():
                host = left.strip()
                port = int(right)

        host = host.strip().rstrip("/")
        if not host:
            raise ValueError("A target hostname is required.")
        if port is None:
            port = 443
        if port < 1 or port > 65535:
            raise ValueError(f"Invalid port: {port}")
        return f"{host}:{port}"

    def build_plan(
        self,
        kind: str,
        *,
        target: str,
        extra: str | None = None,
    ) -> ScanPlan:
        """Build an sslyze command.

        `kind` is one of: cert, scan, protocols, heartbleed, custom.

        JSON is written to a temp file (`--json_out=path`). SSLyze 6.3+ rejects
        combining `--quiet` with `--json_out=-` (stdout).
        """
        binary = self._base_binary()
        label = self.normalize_target(target)

        fd, out_path = tempfile.mkstemp(prefix="aril-sslyze-", suffix=".json")
        os.close(fd)
        # Quiet + file JSON is the supported machine-readable path.
        command = [binary, "--quiet", f"--json_out={out_path}"]

        if kind == "cert":
            command.append("--certinfo")
            command.append("--mozilla_config=disable")
        elif kind == "protocols":
            command.extend(
                [
                    "--mozilla_config=disable",
                    "--sslv2",
                    "--sslv3",
                    "--tlsv1",
                    "--tlsv1_1",
                    "--tlsv1_2",
                    "--tlsv1_3",
                ]
            )
        elif kind == "heartbleed":
            command.extend(
                [
                    "--mozilla_config=disable",
                    "--heartbleed",
                    "--openssl_ccs",
                    "--robot",
                    "--compression",
                    "--fallback",
                ]
            )
        elif kind == "custom":
            flags = (extra or "").strip()
            if not flags:
                raise ValueError(
                    "Provide SSLyze flags in 'args' (do NOT include 'sslyze' or the target)."
                )
            if _UNSAFE_ARGS.search(flags):
                raise ValueError("Custom args contain unsafe characters.")
            parts = flags.split()
            for part in parts:
                if part.startswith("-"):
                    continue
                if "://" in part or (
                    part.count(".") >= 1 and ":" in part and not part.startswith("/")
                ):
                    raise ValueError("Put the scan target in 'target', not in 'args'.")
            command.extend(parts)
        else:  # scan — Mozilla intermediate profile (SSLyze default)
            command.append("--mozilla_config=intermediate")

        command.append(label)
        return ScanPlan(command=command, target_label=label, json_out_path=out_path)

    async def run_streaming(
        self, command: list[str], *, json_out_path: str | None = None
    ) -> AsyncIterator[tuple[str, str]]:
        """Run sslyze, yielding ('progress', line) then ('result', json).

        stderr may carry warnings; JSON is read from `json_out_path` when set.
        """
        try:
            proc = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as exc:
            raise SSLyzeNotFoundError(_INSTALL_HINT) from exc

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
                        f"sslyze scan timed out after {self.scan_timeout}s."
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
        out = ""
        if json_out_path:
            try:
                out = Path(json_out_path).read_text(encoding="utf-8")
            except OSError:
                out = ""
            finally:
                try:
                    Path(json_out_path).unlink(missing_ok=True)
                except OSError:
                    pass
        if not out.strip():
            out = stdout.decode("utf-8", errors="replace")
        if proc.returncode not in (0, None) and not out.strip():
            tail = " ".join(err_tail[-3:]).strip()
            raise RuntimeError(f"sslyze failed: {tail or 'unknown error'}")
        yield ("result", out)

    def summarize(self, json_output: str) -> str:
        """Turn sslyze --json_out output into a compact, model-friendly text report."""
        raw = (json_output or "").strip()
        if not raw:
            return "No output from sslyze."
        # SSLyze may print warnings before JSON; find the document root.
        start = raw.find("{")
        if start > 0:
            raw = raw[start:]
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return raw[:8000]

        lines: list[str] = []
        version = data.get("sslyze_version") or ""
        header = "SSLyze"
        if version:
            header += f" {version}"
        results = data.get("server_scan_results") or []
        invalid = data.get("invalid_server_strings") or []
        lines.append(f"{header}: {len(results)} target(s).")

        if invalid:
            lines.append("")
            lines.append("## Failed targets")
            for item in invalid[:10]:
                if not isinstance(item, dict):
                    lines.append(f"- {item}")
                    continue
                server = item.get("server_string") or "?"
                err = item.get("error_message") or "unknown error"
                lines.append(f"- {server}: {err}")
            if not results:
                lines.append("")
                lines.append(
                    "No successful scans. Check the hostname spelling and DNS resolution."
                )

        for result in results[:5]:
            loc = result.get("server_location") or {}
            host = loc.get("hostname") or "?"
            port = loc.get("port") or "?"
            ip = loc.get("ip_address") or ""
            lines.append("")
            lines.append(f"## {host}:{port}" + (f" ({ip})" if ip else ""))

            conn = result.get("connectivity_result") or {}
            if conn:
                tls = conn.get("highest_tls_version_supported")
                cipher = conn.get("cipher_suite_supported")
                if tls or cipher:
                    bits = [b for b in (tls, cipher) if b]
                    lines.append("- Connectivity: " + " · ".join(str(b) for b in bits))

            status = result.get("scan_status") or result.get("connectivity_status")
            if status and status != "COMPLETED":
                lines.append(f"- Scan status: {status}")
                err = result.get("connectivity_error_trace")
                if err:
                    lines.append(f"  {str(err)[:300]}")
                continue

            scan = result.get("scan_result") or {}
            if not isinstance(scan, dict):
                continue

            cert_block = scan.get("certificate_info") or {}
            if isinstance(cert_block, dict) and cert_block.get("status") == "COMPLETED":
                lines.extend(_summarize_certificate_info(cert_block.get("result") or {}))

            for key, label in (
                ("heartbleed", "Heartbleed"),
                ("openssl_ccs_injection", "OpenSSL CCS"),
                ("robot", "ROBOT"),
                ("tls_compression", "TLS compression (CRIME)"),
                ("tls_fallback_scsv", "TLS_FALLBACK_SCSV"),
                ("http_headers", "HTTP security headers"),
            ):
                block = scan.get(key)
                if not isinstance(block, dict) or block.get("status") != "COMPLETED":
                    continue
                note = _summarize_simple_plugin(label, block.get("result"))
                if note:
                    lines.append(note)

            # Protocol / cipher suites
            for key, label in (
                ("ssl_2_0_cipher_suites", "SSL 2.0"),
                ("ssl_3_0_cipher_suites", "SSL 3.0"),
                ("tls_1_0_cipher_suites", "TLS 1.0"),
                ("tls_1_1_cipher_suites", "TLS 1.1"),
                ("tls_1_2_cipher_suites", "TLS 1.2"),
                ("tls_1_3_cipher_suites", "TLS 1.3"),
            ):
                block = scan.get(key)
                if not isinstance(block, dict) or block.get("status") != "COMPLETED":
                    continue
                note = _summarize_cipher_suites(label, block.get("result"))
                if note:
                    lines.append(note)

            # Mozilla compliance / TLS config checks (key names vary by SSLyze version).
            for key, block in scan.items():
                if not isinstance(block, dict):
                    continue
                low = key.lower()
                if "mozilla" not in low and "tls_configuration" not in low:
                    continue
                if block.get("status") != "COMPLETED":
                    continue
                note = _summarize_mozilla(block.get("result"))
                if note:
                    lines.append(note)

        report = "\n".join(lines).strip()
        return report[:16000] if report else "No output from sslyze."


def _summarize_certificate_info(result: dict) -> list[str]:
    lines: list[str] = []
    deployments = result.get("certificate_deployments") or []
    if not deployments:
        lines.append("- Certificate info: no deployments reported")
        return lines

    dep = deployments[0]
    chain = dep.get("received_certificate_chain") or []
    leaf = chain[0] if chain else {}
    subject = (leaf.get("subject") or {}).get("rfc4514_string") or "?"
    issuer = (leaf.get("issuer") or {}).get("rfc4514_string") or "?"
    not_before = leaf.get("not_valid_before") or "?"
    not_after = leaf.get("not_valid_after") or "?"
    san = leaf.get("subject_alternative_name") or {}
    dns = san.get("dns_names") or []
    pubkey = leaf.get("public_key") or {}
    key_alg = pubkey.get("algorithm") or "?"
    key_size = pubkey.get("key_size")
    curve = pubkey.get("ec_curve_name")
    sig = (leaf.get("signature_hash_algorithm") or {}).get("name") or (
        (leaf.get("signature_algorithm_oid") or {}).get("name")
    )

    lines.append("- Certificate (leaf):")
    lines.append(f"  Subject: {subject}")
    lines.append(f"  Issuer: {issuer}")
    lines.append(f"  Valid: {not_before} → {not_after}")
    if dns:
        shown = ", ".join(str(d) for d in dns[:12])
        extra = f" (+{len(dns) - 12} more)" if len(dns) > 12 else ""
        lines.append(f"  SAN: {shown}{extra}")
    key_bits = f"{key_size}" if key_size else "?"
    key_line = f"  Key: {key_alg} {key_bits}"
    if curve:
        key_line += f" ({curve})"
    if sig:
        key_line += f" · sig {sig}"
    lines.append(key_line)
    lines.append(f"  Chain length: {len(chain)}")

    if dep.get("leaf_certificate_is_ev"):
        lines.append("  EV: yes")
    if dep.get("verified_chain_has_sha1_signature"):
        lines.append("  ⚠ Verified chain contains SHA-1 signature")
    if dep.get("verified_chain_has_legacy_symantec_anchor"):
        lines.append("  ⚠ Legacy Symantec anchor in verified chain")

    # Trust store summary (compact)
    validations = dep.get("path_validation_results") or []
    trusted = 0
    failed_names: list[str] = []
    for item in validations:
        if not isinstance(item, dict):
            continue
        store = (item.get("trust_store") or {}).get("name") or "store"
        # Presence of verified_certificate_chain implies success in SSLyze JSON.
        if item.get("verified_certificate_chain"):
            trusted += 1
        else:
            failed_names.append(str(store))
    if validations:
        lines.append(
            f"  Trust stores: {trusted}/{len(validations)} validated"
            + (f" · failed: {', '.join(failed_names[:4])}" if failed_names else "")
        )
    return lines


def _summarize_simple_plugin(label: str, result: object) -> str | None:
    if result is None:
        return None
    if isinstance(result, bool):
        return f"- {label}: {'VULNERABLE' if result else 'not vulnerable'}"
    if isinstance(result, dict):
        # Common SSLyze shapes: is_vulnerable_to_heartbleed, supports_fallback_scsv, …
        for key, value in result.items():
            if key.startswith("is_vulnerable") or key.endswith("_vulnerable"):
                return f"- {label}: {'VULNERABLE' if value else 'not vulnerable'}"
            if "vulnerable" in key.lower() and isinstance(value, bool):
                return f"- {label}: {'VULNERABLE' if value else 'not vulnerable'}"
            if key.startswith("supports_") and isinstance(value, bool):
                return f"- {label}: {'yes' if value else 'no'}"
        # HTTP headers: list notable ones
        if "headers" in result or any("strict" in k.lower() for k in result):
            bits = []
            for k, v in list(result.items())[:8]:
                if v is None or v is False:
                    continue
                bits.append(f"{k}={v}" if not isinstance(v, bool) else k)
            if bits:
                return f"- {label}: " + "; ".join(str(b) for b in bits[:6])
        return f"- {label}: completed"
    return f"- {label}: {str(result)[:200]}"


def _summarize_cipher_suites(label: str, result: object) -> str | None:
    if not isinstance(result, dict):
        return None
    accepted = result.get("accepted_cipher_suites") or result.get("cipher_suites") or []
    rejected = result.get("rejected_cipher_suites") or []
    if isinstance(accepted, list):
        count = len(accepted)
        names = []
        for item in accepted[:5]:
            if isinstance(item, dict):
                cs = item.get("cipher_suite") or item
                name = cs.get("name") if isinstance(cs, dict) else None
                if name:
                    names.append(str(name))
            elif isinstance(item, str):
                names.append(item)
        sample = f" — {', '.join(names)}" if names else ""
        more = f" (+{count - 5} more)" if count > 5 else ""
        return f"- {label}: {count} accepted suite(s){sample}{more}"
    if accepted:
        return f"- {label}: supported"
    if rejected:
        return f"- {label}: not supported"
    return None


def _summarize_mozilla(result: object) -> str | None:
    if not isinstance(result, dict):
        return None
    # Newer SSLyze may report compliance issues as lists.
    for key in ("issues", "errors", "non_compliant", "status"):
        if key in result:
            val = result[key]
            if isinstance(val, list):
                if not val:
                    return "- Mozilla TLS config: compliant"
                return f"- Mozilla TLS config: {len(val)} issue(s) — " + "; ".join(
                    str(x)[:80] for x in val[:3]
                )
            if isinstance(val, str):
                return f"- Mozilla TLS config: {val}"
    return None
