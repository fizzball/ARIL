"""SSLyze MCP scanner unit tests (no live network required for most cases)."""

from __future__ import annotations

import json

import pytest

from app.sslyze_mcp.scanner import SSLyzeScanner


def test_normalize_target_variants():
    s = SSLyzeScanner()
    assert s.normalize_target("example.com") == "example.com:443"
    assert s.normalize_target("example.com:8443") == "example.com:8443"
    assert s.normalize_target("https://example.com/path") == "example.com:443"
    assert s.normalize_target("http://example.com") == "example.com:80"


def test_normalize_target_rejects_shell_metacharacters():
    s = SSLyzeScanner()
    with pytest.raises(ValueError, match="unsafe"):
        s.normalize_target("example.com; rm -rf /")


def test_build_plan_cert_uses_certinfo(monkeypatch):
    s = SSLyzeScanner(sslyze_path="/usr/bin/false")
    monkeypatch.setattr(s, "resolve_binary", lambda: "/usr/bin/sslyze")
    plan = s.build_plan("cert", target="example.com")
    assert plan.target_label == "example.com:443"
    assert plan.command[0] == "/usr/bin/sslyze"
    assert "--certinfo" in plan.command
    assert any(a.startswith("--json_out=") and a != "--json_out=-" for a in plan.command)
    assert "--quiet" in plan.command
    assert plan.json_out_path
    assert plan.command[-1] == "example.com:443"


def test_summarize_invalid_hostname():
    payload = {
        "sslyze_version": "6.3.1",
        "invalid_server_strings": [
            {
                "server_string": "unify.nsi.com.au:443",
                "error_message": "Could not resolve hostname unify.nsi.com.au",
            }
        ],
        "server_scan_results": [],
    }
    summary = SSLyzeScanner().summarize(json.dumps(payload))
    assert "Could not resolve hostname" in summary
    assert "unify.nsi.com.au" in summary
    assert "No successful scans" in summary


def test_summarize_certificate_json():
    payload = {
        "sslyze_version": "6.2.0",
        "server_scan_results": [
            {
                "server_location": {
                    "hostname": "www.example.com",
                    "port": 443,
                    "ip_address": "93.184.216.34",
                },
                "connectivity_status": "COMPLETED",
                "connectivity_result": {
                    "highest_tls_version_supported": "TLS_1_3",
                    "cipher_suite_supported": "TLS_AES_256_GCM_SHA384",
                },
                "scan_status": "COMPLETED",
                "scan_result": {
                    "certificate_info": {
                        "status": "COMPLETED",
                        "result": {
                            "certificate_deployments": [
                                {
                                    "received_certificate_chain": [
                                        {
                                            "subject": {"rfc4514_string": "CN=www.example.com"},
                                            "issuer": {"rfc4514_string": "CN=Example CA"},
                                            "not_valid_before": "2026-01-01T00:00:00Z",
                                            "not_valid_after": "2027-01-01T00:00:00Z",
                                            "subject_alternative_name": {
                                                "dns_names": ["www.example.com", "example.com"]
                                            },
                                            "public_key": {
                                                "algorithm": "RSAPublicKey",
                                                "key_size": 2048,
                                            },
                                            "signature_hash_algorithm": {"name": "sha256"},
                                        }
                                    ],
                                    "leaf_certificate_is_ev": False,
                                    "verified_chain_has_sha1_signature": False,
                                    "path_validation_results": [
                                        {
                                            "trust_store": {"name": "Mozilla"},
                                            "verified_certificate_chain": [{"as_pem": "x"}],
                                        }
                                    ],
                                }
                            ]
                        },
                    }
                },
            }
        ],
    }
    summary = SSLyzeScanner().summarize(json.dumps(payload))
    assert "SSLyze 6.2.0" in summary
    assert "www.example.com:443" in summary
    assert "CN=www.example.com" in summary
    assert "CN=Example CA" in summary
    assert "TLS_1_3" in summary


@pytest.mark.asyncio
async def test_sslyze_scan_stream_frames():
    """The sslyze server's SSE generator emits progress then a JSON-RPC result."""
    from app.sslyze_mcp import server as ssl_server
    from app.sslyze_mcp.scanner import ScanPlan

    class _FakeScanner:
        def build_plan(self, kind, *, target, extra=None):
            return ScanPlan(command=["sslyze", "--quiet", target], target_label=target)

        async def run_streaming(self, command, *, json_out_path=None):
            yield ("progress", "Checking certificate…")
            yield ("result", json.dumps({"sslyze_version": "6.2.0", "server_scan_results": []}))

        def summarize(self, raw):
            return "SSLyze summary"

    frames = []
    async for frame in ssl_server._scan_stream(
        _FakeScanner(), "sslyze_cert_info", {"target": "example.com"}, 11
    ):
        frames.append(frame)

    assert any("event: progress" in f for f in frames)
    assert any("event: result" in f for f in frames)
    assert any("SSLyze summary" in f for f in frames)
