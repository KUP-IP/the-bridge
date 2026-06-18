#!/usr/bin/env python3
# registry_live_smoke.py — live write-path smoke test for the Data-Source Registry.
#
# Exercises the FULL lifecycle of the registry's CRUD + possess tools against a
# RUNNING Bridge + real Notion, for a configured entity:
#     create → get → (update → get) → (possess) → delete → verify-gone
#
# SAFETY (this script will not touch your existing data):
#   • It only ever operates on the row it CREATES. The new page id is captured
#     from registry_create's result.
#   • Every created row's title carries a unique marker:
#         "🧪 BRIDGE-REGISTRY-SMOKE <uuid> (auto-delete)"
#   • Before deleting, it RE-FETCHES the row and asserts the title still
#     contains "BRIDGE-REGISTRY-SMOKE". If it doesn't, it ABORTS without
#     deleting — so a mis-captured id can never delete a real row.
#   • registry_delete is a SOFT delete (Notion trash), not a permanent purge.
#
# Note: registry_delete is a confirmation-gated tool (.request tier). If you have
# not set it to "Always Allow", a macOS approval prompt appears — approve it and
# the script continues; otherwise the delete step times out and the (clearly
# marked) test row is left for you to remove.
#
# Usage:
#   python3 scripts/registry_live_smoke.py --entity person --title-key name
#   python3 scripts/registry_live_smoke.py --entity skill  --title-key name \
#           --update-key summary --update-long --body
#
import argparse, json, sys, time, uuid, urllib.request

def mcp_session(base):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-06-18","capabilities":{},
        "clientInfo":{"name":"registry-live-smoke","version":"1.0"}}}).encode()
    req = urllib.request.Request(base, data=body, method="POST", headers={
        "Host":"127.0.0.1:9700","Accept":"application/json, text/event-stream",
        "Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        sid = r.headers.get("Mcp-Session-Id")
        r.read()
    if not sid:
        raise RuntimeError("no Mcp-Session-Id (is the Bridge running on this port?)")
    # notifications/initialized
    n = json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"}).encode()
    req = urllib.request.Request(base, data=n, method="POST", headers={
        "Host":"127.0.0.1:9700","Accept":"application/json, text/event-stream",
        "Content-Type":"application/json","Mcp-Session-Id":sid})
    urllib.request.urlopen(req, timeout=15).read()
    return sid

def call(base, sid, name, arguments, timeout=60):
    body = json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/call",
                       "params":{"name":name,"arguments":arguments}}).encode()
    req = urllib.request.Request(base, data=body, method="POST", headers={
        "Host":"127.0.0.1:9700","Accept":"application/json, text/event-stream",
        "Content-Type":"application/json","Mcp-Session-Id":sid})
    raw = urllib.request.urlopen(req, timeout=timeout).read().decode()
    # SSE: find the data line carrying the JSON-RPC envelope.
    env = None
    for line in raw.splitlines():
        if line.startswith("data: ") and ('"result"' in line or '"error"' in line):
            env = json.loads(line[len("data: "):])
    if env is None:
        raise RuntimeError(f"{name}: no result in response: {raw[:200]}")
    if "error" in env:
        raise RuntimeError(f"{name}: {env['error'].get('message')}")
    # tool result content[0].text is itself JSON for these tools.
    text = env["result"]["content"][0]["text"]
    try:
        return json.loads(text)
    except Exception:
        return {"_text": text}

PASS, FAIL = "✅", "❌"
results = []
def check(label, ok, detail=""):
    results.append(ok)
    print(f"  {PASS if ok else FAIL} {label}" + (f" — {detail}" if detail else ""))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--entity", required=True)
    ap.add_argument("--title-key", required=True)
    ap.add_argument("--update-key")
    ap.add_argument("--update-long", action="store_true",
                    help="update value is a 2500-char string (live-tests the >2000-char run chunking)")
    ap.add_argument("--body", action="store_true", help="also run registry_possess")
    ap.add_argument("--port", default="9700")
    a = ap.parse_args()
    base = f"http://127.0.0.1:{a.port}/mcp"
    marker = f"🧪 BRIDGE-REGISTRY-SMOKE {uuid.uuid4().hex[:12]} (auto-delete)"
    print(f"\n▶ live smoke: entity={a.entity}  marker={marker!r}")
    sid = mcp_session(base)

    # 1. CREATE (title only — minimal footprint, no status/relations to trigger automations)
    created = call(base, sid, "registry_create", {"entity":a.entity, "fields":{a.title_key: marker}})
    new_id = created.get("row",{}).get("id","")
    check("create returns a new row id", bool(new_id), new_id)
    if not new_id:
        print("  abort: no id captured."); sys.exit(1)

    # 2. GET — the created row is fetchable + the title round-tripped
    got = call(base, sid, "registry_get", {"entity":a.entity, "id":new_id, "forceRefresh":True})
    title = got.get("title","")
    check("get returns the created row with the marker title", marker in title, title[:48])

    # 3. UPDATE (optional) — a benign content field; --update-long exercises codec chunking live
    if a.update_key:
        val = ("Bridge registry smoke — " + "x"*2500) if a.update_long else f"smoke-update {int(time.time())}"
        call(base, sid, "registry_update", {"entity":a.entity, "id":new_id, "fields":{a.update_key: val}})
        back = call(base, sid, "registry_get", {"entity":a.entity, "id":new_id, "forceRefresh":True})
        got_val = back.get("properties",{}).get(a.update_key, "")
        if a.update_long:
            ok = isinstance(got_val,str) and len(got_val) >= 2500
            check(f"update of long ‘{a.update_key}’ (>2000 chars) round-trips", ok, f"len={len(got_val) if isinstance(got_val,str) else 'n/a'}")
        else:
            check(f"update of ‘{a.update_key}’ round-trips", got_val == val, str(got_val)[:48])

    # 4. POSSESS (optional, body entities)
    if a.body:
        pos = call(base, sid, "registry_possess", {"entity":a.entity, "id":new_id})
        check("possess returns a body field (no error)", "body" in pos, f"{len(pos.get('body',''))} chars")

    # 5. SAFETY RE-CHECK before delete: confirm we are about to delete OUR row.
    confirm = call(base, sid, "registry_get", {"entity":a.entity, "id":new_id, "forceRefresh":True})
    safe = "BRIDGE-REGISTRY-SMOKE" in confirm.get("title","")
    check("pre-delete marker guard (only the test row is deletable)", safe)
    if not safe:
        print("  ABORT: marker guard failed — NOT deleting."); sys.exit(1)

    # 6. DELETE (soft archive). May prompt for approval (.request tier).
    try:
        call(base, sid, "registry_delete", {"entity":a.entity, "id":new_id}, timeout=45)
        deleted = True
    except Exception as e:
        deleted = False
        print(f"  ⚠️  delete did not complete ({e}). Approve the prompt, or delete the marked row manually: {new_id}")
    if deleted:
        check("delete (soft archive) succeeded", True)
        gone = call(base, sid, "registry_get", {"entity":a.entity, "id":new_id, "forceRefresh":True}) if True else None
        # After archive, the page is in trash; a fetch should fail or return empty.
        # We accept either an error (caught below) or an empty/absent title.
    # 7. VERIFY GONE
    if deleted:
        try:
            after = call(base, sid, "registry_get", {"entity":a.entity, "id":new_id, "forceRefresh":True})
            check("row is gone after delete (trashed)", (after.get("title","") == "" or "in_trash" in str(after)), str(after)[:60])
        except Exception:
            check("row is gone after delete (fetch now 404s)", True)

    ok = all(results)
    print(f"\n{'ALL PASSED' if ok else 'SOME FAILED'} — {sum(results)}/{len(results)} checks for entity={a.entity}")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
