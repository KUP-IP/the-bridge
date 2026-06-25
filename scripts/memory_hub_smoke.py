#!/usr/bin/env python3
"""Memory Hub + regression MCP smoke (local Streamable HTTP). Exit 0 if all pass."""
from __future__ import annotations

import json
import sys
import urllib.request

BASE = "http://127.0.0.1:9700/mcp"
HOST = "127.0.0.1:9700"
results: list[tuple[str, bool, str]] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    results.append((label, ok, detail))
    mark = "✅" if ok else "❌"
    print(f"  {mark} {label}" + (f" — {detail}" if detail else ""))


def mcp_session() -> str:
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "memory-hub-smoke", "version": "1.0"},
            },
        }
    ).encode()
    req = urllib.request.Request(
        BASE,
        data=body,
        method="POST",
        headers={
            "Host": HOST,
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        sid = r.headers.get("Mcp-Session-Id")
        r.read()
    if not sid:
        raise RuntimeError("no Mcp-Session-Id")
    n = json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}).encode()
    req = urllib.request.Request(
        BASE,
        data=n,
        method="POST",
        headers={
            "Host": HOST,
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "Mcp-Session-Id": sid,
        },
    )
    urllib.request.urlopen(req, timeout=20).read()
    return sid


def call(sid: str, name: str, arguments: dict | None = None, timeout: int = 120) -> dict:
    arguments = arguments or {}
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
    ).encode()
    req = urllib.request.Request(
        BASE,
        data=body,
        method="POST",
        headers={
            "Host": HOST,
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "Mcp-Session-Id": sid,
        },
    )
    raw = urllib.request.urlopen(req, timeout=timeout).read().decode()
    env = None
    for line in raw.splitlines():
        if line.startswith("data: ") and ('"result"' in line or '"error"' in line):
            env = json.loads(line[6:])
    if env is None:
        raise RuntimeError(f"{name}: no SSE result: {raw[:400]}")
    if "error" in env:
        raise RuntimeError(f"{name}: {env['error']}")
    text = env["result"]["content"][0]["text"]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"_text": text}


def main() -> int:
    print("\n▶ Memory Hub + regression MCP smoke\n")
    sid = mcp_session()

    # Regression — core surfaces
    health = json.loads(
        urllib.request.urlopen("http://127.0.0.1:9700/health", timeout=5).read()
    )
    check("health running", health.get("status") == "running", f"tools={health.get('tools')}")

    sess = call(sid, "session_info", {})
    check("session_info", "uptime" in sess or sess.get("ok") is not False, str(sess)[:80])

    tools = call(sid, "tools_list", {})
    tool_names = {t["name"] for t in tools} if isinstance(tools, list) else set()
    check("tools_list ≥180", len(tool_names) >= 180, f"count={len(tool_names)}")

    reg = call(sid, "registry_entities", {})
    entities = reg.get("entities", reg) if isinstance(reg, dict) else reg
    check("registry_entities", isinstance(entities, list) and len(entities) >= 1, f"n={len(entities) if isinstance(entities,list) else '?'}")

    skills = call(sid, "skills_routing_list", {})
    check("skills_routing_list", skills is not None, "")

    ollama = call(sid, "ollama_health", {})
    check("ollama_health (reachable or explicit fail)", "ok" in ollama or "error" in ollama or "reachable" in str(ollama).lower(), str(ollama)[:60])

    # New — Memory Hub navigation
    nav = call(sid, "bridge_settings_navigate", {"section": "Memory", "anchor": "inbox", "focus": True})
    check("bridge_settings_navigate Memory/inbox", nav.get("success") is True, str(nav))

    open_nav = call(sid, "bridge_open_settings", {"section": "Memory", "anchor": "notion"})
    check("bridge_open_settings Memory/notion", open_nav.get("success") is True or open_nav.get("opened") is True, str(open_nav)[:80])

    legacy = call(sid, "bridge_settings_navigate", {"section": "voice-memos", "anchor": "inbox"})
    check("legacy voice-memos alias → Memory", legacy.get("section") == "Memory" or legacy.get("success"), str(legacy)[:80])

    adv = call(sid, "bridge_settings_navigate", {"section": "Advanced", "anchor": "local-models"})
    check("Advanced local-models anchor", adv.get("success") is True, str(adv)[:60])

    # New — voice memo tools
    for t in ["voice_memo_get", "voice_memo_commit", "memory_forget"]:
        if t in tool_names:
            check(f"tool registered: {t}", True, "")
        else:
            check(f"tool registered: {t}", False, "missing from tools_list")

    proc_nav = call(sid, "bridge_settings_navigate", {"section": "Memory", "anchor": "process", "focus": True})
    check("bridge_settings_navigate Memory/process", proc_nav.get("success") is True, str(proc_nav)[:80])

    reviews = call(sid, "voice_memo_review_list", {})
    pending = reviews if isinstance(reviews, list) else reviews.get("entries", [])
    if isinstance(reviews, dict) and "count" in reviews:
        n = reviews["count"]
    else:
        n = len(pending) if isinstance(pending, list) else 0
    check("voice_memo_review_list", n >= 0, f"pending={n}")

    memos = call(sid, "voice_memo_list", {})
    memo_items = memos.get("memos", []) if isinstance(memos, dict) else memos
    count = memos.get("count", len(memo_items)) if isinstance(memos, dict) else len(memo_items)
    check("voice_memo_list discovers memos", count > 0, f"count={count}")

    target = None
    for m in memo_items if isinstance(memo_items, list) else []:
        path = str(m.get("path", "")) + str(m.get("title", ""))
        if "20260613" in path:
            target = m
            break
    check("20260613 memo in voice_memo_list", target is not None, target.get("transcriptSource") if target else "missing")
    if target:
        check("transcriptSource on 20260613", bool(target.get("transcriptSource")), str(target.get("transcriptSource")))

    # New — registry memory tab backend
    mem_rows = call(sid, "registry_list", {"entity": "memory", "limit": 3})
    rows = mem_rows.get("rows", mem_rows) if isinstance(mem_rows, dict) else mem_rows
    rc = len(rows) if isinstance(rows, list) else mem_rows.get("count", 0)
    check("registry_list memory entity", rc >= 1, f"rows={rc}")

    recall = call(sid, "memory_recall", {"query": "voice memo smoke", "limit": 3})
    check("memory_recall", recall is not None, "")

    # Notification deep-link payload (no UI assert)
    note = call(
        sid,
        "notify",
        {
            "title": "Smoke: Memory Inbox",
            "body": "Tap to validate deep-link",
            "openSettingsSection": "Memory",
            "openSettingsAnchor": "inbox",
        },
    )
    check("notify with Memory deep-link args", note.get("sent") is True, str(note))

    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print(f"\n{'='*50}\nSmoke: {passed}/{total} passed\n{'='*50}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
