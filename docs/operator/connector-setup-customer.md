# Connect Claude to The Bridge (Local Mac)

Customer-facing setup for connecting Claude — Desktop or Code — to The Bridge over
the local loopback connection. This is the standard setup for running The Bridge
on your own Mac.

## What you're connecting to

- **Endpoint:** `http://127.0.0.1:9700/mcp`
- **Transport:** Streamable HTTP
- **Token:** **none.** The local connection on your own Mac is token-free — there
  is nothing to paste, no API key, no OAuth.
- **Requirement:** The Bridge app must be **running** (it's a menu-bar app — look
  for its icon in the menu bar).

## Steps

1. **Launch The Bridge.** Open the app; confirm its icon is in the menu bar. It
   serves MCP on `127.0.0.1:9700` while running.

2. **Add the MCP server in your Claude client:**
   - **Claude Code** — add an HTTP MCP server pointing at
     `http://127.0.0.1:9700/mcp` (Streamable HTTP). For example:
     ```sh
     claude mcp add --transport http the-bridge http://127.0.0.1:9700/mcp
     ```
     No header or token is required.
   - **Claude Desktop** — add a custom MCP connector with the URL
     `http://127.0.0.1:9700/mcp`, transport **Streamable HTTP**, **no
     authentication**.

3. **Verify.** Start a new conversation and ask the client to list its tools, or
   call `system_info`. If The Bridge's tools appear, you're connected.

That's it — there is no key to enter for the local connection.

## Quick self-check

If the client can't connect, confirm the server is alive first:

```sh
curl -s http://127.0.0.1:9700/health
```

A JSON response means The Bridge is up and listening; re-check that your client
URL is exactly `http://127.0.0.1:9700/mcp`. Connection refused means the app isn't
running (launch it) or HTTP isn't enabled on this Mac.

## If it disconnects after an update

The Bridge auto-updates via Sparkle and briefly restarts. The local connection is
**token-free**, so once the app is back in the menu bar your client should
**reconnect on its own**. If it doesn't pick back up, simply **re-add the endpoint**
(`http://127.0.0.1:9700/mcp`, no token) — nothing about the connection details
changes across updates.

---

*Remote access (reaching The Bridge from claude.ai / mobile over a Cloudflare
tunnel) is a separate, authenticated setup and is not covered here — local
loopback is token-free by design.*
