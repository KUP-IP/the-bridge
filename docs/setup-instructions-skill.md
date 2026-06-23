# The Bridge — setup instructions (skill page template)

Copy into a Notion skill page. Adjust URLs if your Advanced port or tunnel differs.

## Local MCP (same Mac)

- Default: `http://127.0.0.1:9700/mcp` (Streamable HTTP). Health: `http://127.0.0.1:9700/health`.
- If you changed **Advanced → SSE Port**: use that port instead. **Restart The Bridge** after saving.

## Remote MCP (another machine / Notion in cloud)

- Notion does not talk to `localhost` on your Mac. Use **Connections → Remote Access** and a tunnel (e.g. Cloudflare) that forwards HTTPS to `http://127.0.0.1:<yourPort>/mcp`.
- If you change the app port, update the tunnel command (e.g. `cloudflared tunnel --url http://localhost:<port>`) to match.

## Stripe / API keys

- **API connections** in Settings — not the same as Notion workspace tokens.

## Skills metadata (optional)

- MCP fields: summary, triggers, anti-triggers. Sync to Notion with `manage_skill` → `sync_metadata_to_notion` after adding properties **Bridge Summary**, **Bridge Triggers**, **Bridge Anti-triggers** on the skill page.
