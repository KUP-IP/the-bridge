# The Bridge — Privacy Policy (DRAFT for review — NOT published)

> Intended to be served at a stable URL (e.g. https://kup.solutions/privacy) for the
> Anthropic Connectors Directory submission. Review + edit before publishing. Effective date: TBD.

## What The Bridge is
The Bridge is a Model Context Protocol (MCP) connector that lets AI agents you authorize
operate **your own Mac** — its files, applications, and local tools — on your behalf. It is
single-tenant: each user runs their own Bridge on their own Mac with their own accounts.

## What data is processed
- **Tool requests and results.** When an authorized agent calls a tool, the request (tool
  name + arguments) and its result (e.g., file contents, command output) transit the
  connection between the agent and your Mac. These are the contents of the actions you ask
  the agent to perform.
- **OAuth identity.** Sign-in is handled by WorkOS AuthKit. We receive an authenticated
  user identifier and session token to authorize access to *your* Bridge. We do not receive
  your password.

## What never leaves your Mac
- **Your credentials and API keys** (e.g., Notion, Stripe, WorkOS) live only in your Mac's
  Keychain. Tools use them locally; the agent and the cloud receive *results*, never the keys.
- The Bridge does not copy your files, messages, or data to our servers. There is no
  Bridge-operated data store of your content.

## The cloud path
For remote access, requests reach your Mac through a Cloudflare tunnel terminating at the
Bridge on your machine. TLS terminates at Cloudflare's edge before re-encrypting into the
tunnel; treat the tunnel as you would any TLS-terminated CDN. The control plane (provisioning,
liveness heartbeat, OAuth) records operational metadata (account id, tenant id, last-seen
timestamp) — not your tool contents.

## Retention
- Tool contents are not retained by the cloud — they pass through to your Mac and back.
- Operational metadata (account/tenant/heartbeat) is retained only as needed to run the service.
- Local audit logs and memory live on your Mac, under your control.

## Your controls
- Disconnect the connector at any time from your agent client.
- Per-tool security gates (open / notify / confirm) and Touch-ID-gated credentials run on
  your Mac; destructive actions require your approval.
- Disable remote access to make the Bridge local-only.

## Contact
isaiah@kup.solutions
