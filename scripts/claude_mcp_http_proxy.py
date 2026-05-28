#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
import urllib.error

# v3.6.0 rename: prefer THE_BRIDGE_* env vars (current); fall back to
# NOTION_BRIDGE_* (legacy). Old Claude Desktop / Cursor configs that still
# use NOTION_BRIDGE_* keep working; new configs that use THE_BRIDGE_*
# (per README) work too. First non-empty wins.
URL = (
    os.environ.get("THE_BRIDGE_URL")
    or os.environ.get("NOTION_BRIDGE_URL")
    or "http://127.0.0.1:9700/mcp"
)
BEARER = (
    os.environ.get("THE_BRIDGE_BEARER")
    or os.environ.get("NOTION_BRIDGE_BEARER")
    or ""
)
CLIENT_NAME = (
    os.environ.get("THE_BRIDGE_CLIENT_NAME")
    or os.environ.get("NOTION_BRIDGE_CLIENT_NAME")
    or ""
)
SESSION_ID = None
LAST_INITIALIZE = None


def log(*parts):
	print("[claude_mcp_http_proxy]", *parts, file=sys.stderr, flush=True)


def emit(obj):
	sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
	sys.stdout.flush()


def emit_error(msg_id, message, code=-32000):
	if msg_id is None:
		log("error without id:", message)
		return
	emit({
		"jsonrpc": "2.0",
		"id": msg_id,
		"error": {
			"code": code,
			"message": message,
		},
	})


def parse_sse_payload(text):
	messages = []
	event = None
	data_lines = []

	def flush_event():
		nonlocal event, data_lines
		if data_lines:
			payload = "\n".join(data_lines).strip()
			if payload:
				messages.append((event or "message", payload))
		event = None
		data_lines = []

	for raw_line in text.splitlines():
		line = raw_line.rstrip("\r")
		if not line:
			flush_event()
			continue
		if line.startswith(":"):
			continue
		if line.startswith("event:"):
			event = line.split(":", 1)[1].strip()
			continue
		if line.startswith("data:"):
			data_lines.append(line.split(":", 1)[1].lstrip())
			continue
		if line.startswith("id:"):
			continue
		# Fallback for plain JSON bodies.
		data_lines.append(line)
	flush_event()
	return messages


def post_message(message):
	global SESSION_ID
	headers = {
		"Content-Type": "application/json",
		"Accept": "application/json, text/event-stream",
	}
	if BEARER:
		headers["Authorization"] = f"Bearer {BEARER}"
	if SESSION_ID:
		headers["Mcp-Session-Id"] = SESSION_ID

	data = json.dumps(message).encode("utf-8")
	req = urllib.request.Request(URL, data=data, headers=headers, method="POST")
	with urllib.request.urlopen(req, timeout=60) as resp:
		new_session = resp.headers.get("Mcp-Session-Id")
		if new_session:
			SESSION_ID = new_session
		body = resp.read().decode("utf-8", errors="replace")
		content_type = resp.headers.get("Content-Type", "")
		status = getattr(resp, "status", None)
		return status, content_type, body


def handle_message(message):
    global LAST_INITIALIZE
    msg_id = message.get("id") if isinstance(message, dict) else None
    # Inject custom clientInfo.name if configured via NOTION_BRIDGE_CLIENT_NAME
    if CLIENT_NAME and isinstance(message, dict) and message.get("method") == "initialize":
        params = message.setdefault("params", {})
        ci = params.setdefault("clientInfo", {})
        ci["name"] = CLIENT_NAME
    if isinstance(message, dict) and message.get("method") == "initialize":
        LAST_INITIALIZE = json.loads(json.dumps(message))
    try:
        status, content_type, body = post_message(message)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        retry = maybe_retry_after_expired_session(message, body, e.code)
        if retry is not None:
            status, content_type, body = retry
        else:
            emit_error(msg_id, f"HTTP {e.code}: {body or e.reason}")
            return
    except Exception as e:
        emit_error(msg_id, str(e))
        return

    emit_response(msg_id, status, content_type, body)


def maybe_retry_after_expired_session(message, body, status_code):
    global SESSION_ID
    expired = status_code in (400, 404) and (
        "Session not found" in body or "Session not found or expired" in body
    )
    if not expired:
        return None
    log("session expired; clearing Mcp-Session-Id and retrying")
    SESSION_ID = None
    if isinstance(message, dict) and message.get("method") != "initialize" and LAST_INITIALIZE is not None:
        try:
            post_message(LAST_INITIALIZE)
        except Exception as e:
            log("initialize replay failed", e)
            return None
    try:
        return post_message(message)
    except urllib.error.HTTPError as e:
        retry_body = e.read().decode("utf-8", errors="replace")
        log("retry failed", e.code, retry_body[:500])
        return None
    except Exception as e:
        log("retry failed", e)
        return None


def emit_response(msg_id, status, content_type, body):
    if status == 202 and not body.strip():
        return

    if "text/event-stream" in content_type or body.lstrip().startswith("id:") or "\nevent:" in body or "\ndata:" in body:
        for event_name, payload in parse_sse_payload(body):
            if event_name not in ("message", ""):
                log("ignoring SSE event", event_name)
                continue
            try:
                parsed = json.loads(payload)
            except Exception:
                log("non-JSON SSE payload", payload[:500])
                continue
            emit(parsed)
        return

    if not body.strip():
        return

    try:
        parsed = json.loads(body)
    except Exception:
        emit_error(msg_id, f"Unparseable response body: {body[:500]}")
        return
    emit(parsed)


def main():
	log("starting", URL)
	for raw in sys.stdin:
		line = raw.strip()
		if not line:
			continue
		try:
			message = json.loads(line)
		except Exception as e:
			log("invalid stdin JSON", e, line[:500])
			continue
		handle_message(message)
	log("stdin closed")


if __name__ == "__main__":
	main()
