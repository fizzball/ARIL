"""Thin wrapper around the local `nmap` binary with XML → text summarization."""

from __future__ import annotations

import asyncio
import shlex
import shutil
from collections.abc import AsyncIterator
from dataclasses import dataclass

# Use defusedxml to parse nmap's XML: the stdlib parser is vulnerable to XXE
# (external-entity / billion-laughs) attacks, and scan output can embed
# attacker-influenced text (service banners, NSE script output).
from defusedxml.ElementTree import ParseError, fromstring as _xml_fromstring
from defusedxml.common import DefusedXmlException

# Progress cadence for live streaming (nmap prints stats to stderr this often).
_STATS_EVERY = "2s"


class NmapNotFoundError(RuntimeError):
    """Raised when the nmap binary cannot be located."""


@dataclass
class NmapScanner:
    nmap_path: str = "nmap"
    scan_timeout: int = 300

    def resolve_binary(self) -> str | None:
        """Return an executable nmap path, searching PATH + common install dirs."""
        candidate = self.nmap_path or "nmap"
        found = shutil.which(candidate)
        if found:
            return found
        for path in ("/opt/homebrew/bin/nmap", "/usr/local/bin/nmap", "/usr/bin/nmap"):
            if shutil.which(path):
                return path
        return None

    def _base_binary(self) -> str:
        binary = self.resolve_binary()
        if not binary:
            raise NmapNotFoundError(
                "nmap is not installed or not on PATH. Install it with "
                "`brew install nmap` and try again."
            )
        return binary

    def build_command(self, kind: str, *, target: str, ports: str | None, extra: str | None) -> list[str]:
        binary = self._base_binary()
        target = (target or "").strip()
        if kind != "custom" and not target:
            raise ValueError("A target host or IP is required.")

        # `-v --stats-every` makes nmap emit live progress + port discovery to
        # stderr so the scan can be streamed as it runs (XML result stays on stdout).
        prog = ["-v", "--stats-every", _STATS_EVERY]

        if kind == "quick":
            cmd = [binary, *prog, "-F", "-T4", "-oX", "-", target]
        elif kind == "full":
            cmd = [binary, *prog, "-p", "1-65535", "-T4", "-sV", "-oX", "-", target]
        elif kind == "service":
            cmd = [binary, *prog, "-sV", "-oX", "-"]
            if ports:
                cmd += ["-p", ports]
            cmd.append(target)
        elif kind == "vuln":
            cmd = [binary, *prog, "-sV", "--script", "vuln", "-oX", "-"]
            if ports:
                cmd += ["-p", ports]
            cmd.append(target)
        elif kind == "custom":
            parts = shlex.split(extra or "")
            if not parts:
                raise ValueError("Custom scan requires nmap arguments.")
            # Strip a leading `nmap` if the model included it.
            if parts[0] in ("nmap", binary):
                parts = parts[1:]
            cmd = [binary, *prog, "-oX", "-", *parts]
        else:
            raise ValueError(f"Unknown scan kind: {kind}")
        return cmd

    async def run(self, command: list[str]) -> str:
        try:
            proc = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as exc:
            raise NmapNotFoundError(
                "nmap is not installed or not on PATH. Install it with "
                "`brew install nmap` and try again."
            ) from exc

        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=self.scan_timeout
            )
        except asyncio.TimeoutError as exc:
            proc.kill()
            await proc.wait()
            raise RuntimeError(
                f"nmap scan timed out after {self.scan_timeout}s."
            ) from exc

        out = stdout.decode("utf-8", errors="replace")
        err = stderr.decode("utf-8", errors="replace")
        if proc.returncode != 0 and not out.strip():
            raise RuntimeError(f"nmap failed: {err.strip() or 'unknown error'}")
        return out

    async def run_streaming(
        self, command: list[str]
    ) -> AsyncIterator[tuple[str, str]]:
        """Run nmap, yielding ('progress', line) as it scans then ('result', xml).

        stderr carries `-v`/`--stats-every` progress; stdout carries the `-oX -`
        XML result (drained concurrently to avoid pipe-buffer deadlock).
        """
        try:
            proc = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as exc:
            raise NmapNotFoundError(
                "nmap is not installed or not on PATH. Install it with "
                "`brew install nmap` and try again."
            ) from exc

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
                        f"nmap scan timed out after {self.scan_timeout}s."
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
        if proc.returncode != 0 and not out.strip():
            tail = " ".join(err_tail[-3:]).strip()
            raise RuntimeError(f"nmap failed: {tail or 'unknown error'}")
        yield ("result", out)

    def summarize(self, xml_output: str) -> str:
        """Turn nmap XML into a compact, model-friendly text report."""
        try:
            root = _xml_fromstring(xml_output)
        except (ParseError, DefusedXmlException):
            text = xml_output.strip()
            return text[:8000] if text else "No output from nmap."

        args = root.get("args", "")
        lines: list[str] = []
        if args:
            lines.append(f"Command: {args}")

        hosts = root.findall("host")
        if not hosts:
            lines.append("No hosts responded (target may be down or filtered).")
            return "\n".join(lines)

        for host in hosts:
            status_el = host.find("status")
            state = status_el.get("state", "unknown") if status_el is not None else "unknown"

            address = "unknown"
            for addr in host.findall("address"):
                if addr.get("addrtype") in ("ipv4", "ipv6"):
                    address = addr.get("addr", address)
                    if addr.get("addrtype") == "ipv4":
                        break

            hostname = ""
            hostnames_el = host.find("hostnames")
            if hostnames_el is not None:
                hn = hostnames_el.find("hostname")
                if hn is not None:
                    hostname = hn.get("name", "")

            header = f"Host {address}"
            if hostname:
                header += f" ({hostname})"
            header += f" — {state}"
            lines.append("")
            lines.append(header)

            ports_el = host.find("ports")
            open_ports = 0
            if ports_el is not None:
                for port in ports_el.findall("port"):
                    port_id = port.get("portid", "?")
                    proto = port.get("protocol", "tcp")
                    st_el = port.find("state")
                    st = st_el.get("state", "unknown") if st_el is not None else "unknown"
                    svc_el = port.find("service")
                    svc = ""
                    if svc_el is not None:
                        name = svc_el.get("name", "")
                        product = svc_el.get("product", "")
                        version = svc_el.get("version", "")
                        svc = " ".join(x for x in (name, product, version) if x).strip()
                    if st == "open":
                        open_ports += 1
                    detail = f"  {port_id}/{proto}  {st}"
                    if svc:
                        detail += f"  {svc}"
                    lines.append(detail)

                    # Surface NSE script findings (e.g. `vuln` category output).
                    for script in port.findall("script"):
                        sid = script.get("id", "")
                        soutput = (script.get("output", "") or "").strip()
                        if soutput:
                            trimmed = soutput.replace("\n", "\n      ")
                            lines.append(f"    [{sid}] {trimmed}")

            # Host-level scripts (some vuln scripts attach here).
            hostscript = host.find("hostscript")
            if hostscript is not None:
                for script in hostscript.findall("script"):
                    sid = script.get("id", "")
                    soutput = (script.get("output", "") or "").strip()
                    if soutput:
                        trimmed = soutput.replace("\n", "\n      ")
                        lines.append(f"    [{sid}] {trimmed}")

            if ports_el is not None and open_ports == 0:
                lines.append("  No open ports found.")

        report = "\n".join(lines).strip()
        return report[:16000] if report else "No output from nmap."
