#!/usr/bin/env python3
"""Smoke-test local Streamable HTTP MCP: GET /health + POST /mcp initialize.

Requires The Bridge running (menu bar). Port: NOTION_BRIDGE_PORT env or arg (default 9700).

Exit 0 on success; non-zero if connection refused or non-200/expected errors.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def main() -> int:
    port_s = os.environ.get("NOTION_BRIDGE_PORT", "").strip()
    if not port_s and len(sys.argv) > 1:
        port_s = sys.argv[1].strip()
    port = int(port_s) if port_s else 9700

    base = f"http://127.0.0.1:{port}"
    health_url = f"{base}/health"
    mcp_url = f"{base}/mcp"

    try:
        with urllib.request.urlopen(health_url, timeout=5) as r:
            body = r.read().decode("utf-8", errors="replace")
            if r.status != 200:
                print(f"FAIL health HTTP {r.status}", file=sys.stderr)
                return 1
            print("health OK:", body[:300])
    except urllib.error.URLError as e:
        print(
            f"FAIL: could not reach {health_url} — is The Bridge running? ({e})",
            file=sys.stderr,
        )
        return 2

    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "qa_local_mcp_smoke", "version": "1.0"},
        },
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        mcp_url,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            out = r.read().decode("utf-8", errors="replace")
            if r.status not in (200, 201):
                print(f"FAIL initialize HTTP {r.status}", out[:500], file=sys.stderr)
                return 3
            print("initialize OK (first 500 chars):", out[:500])
    except urllib.error.HTTPError as e:
        print(f"FAIL initialize HTTP {e.code}", e.read().decode("utf-8", errors="replace")[:500], file=sys.stderr)
        return 4
    except urllib.error.URLError as e:
        print(f"FAIL initialize: {e}", file=sys.stderr)
        return 5

    print("Smoke test passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
