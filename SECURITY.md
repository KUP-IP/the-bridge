# Security policy — TheBridge

## Supported versions

Security fixes are applied to the **latest release** on [GitHub Releases](https://github.com/KUP-IP/Notion-bridge/releases). Use Sparkle (in-app updates) or download the current DMG from the product page.

## Reporting a vulnerability

Email **isaiah@kup.solutions** with subject line `TheBridge security` and include:

- Description and impact
- Affected version(s) and platform (macOS / Apple Silicon)
- Steps to reproduce (proof-of-concept if possible)
- Whether you need coordinated disclosure

We aim to acknowledge within **5 business days** and to ship fixes as patch releases when practical.

**Please do not** file public GitHub issues for undisclosed vulnerabilities.

## Scope (in scope)

- Remote code execution, privilege escalation, or sandbox escape **via the TheBridge app or its MCP surface** when used as documented
- Sparkle update integrity (signature verification bypass), if applicable to our distribution
- Issues in bundled first-party code under our control

## Remote MCP and HTTPS tunnels

TheBridge’s Streamable HTTP listener binds to **loopback** only (`127.0.0.1`). Remote access depends on a tunnel or reverse proxy that forwards public HTTPS to that port.

**Threat model (remote):** Anyone who can reach your tunnel URL could otherwise send MCP requests as if they were on your machine. Mitigations should be layered:

1. **Edge / identity** — Prefer **Cloudflare Zero Trust Access** (or equivalent) on the tunnel hostname so anonymous internet clients cannot reach the origin. Use an Access policy that matches how your MCP client authenticates (e.g. service token headers). Browser-hosted MCP clients such as Claude chat may be unable to send those headers, and browser challenges or Browser Integrity Check on `/mcp` can block valid traffic before it reaches TheBridge. In those cases, use a **path-scoped bypass for `POST /mcp` only** rather than a whole-host bypass. See [docs/operator/cloudflare-access-notion-bridge.md](docs/operator/cloudflare-access-notion-bridge.md) for a no-secrets runbook and links to Cloudflare documentation.
2. **App-enforced bearer** — When **Settings → Connections → Remote access** has a **tunnel URL** that parses to a host allowlist, TheBridge **requires** a configured **MCP remote token** for **`POST /mcp`** (fail closed). Configure the token in the same UI; set your MCP client’s headers to `Authorization: Bearer <token>`. The secret is stored in the **Keychain** when running the app bundle, with **`com.notionbridge.mcpBearerToken`** in UserDefaults as a legacy/migration read path.

**Health endpoint:** `GET /health` remains informational unless you add separate edge or app policy later; do not rely on it alone for confidentiality.

## Out of scope

- **Physical access** or unlocked user session — TheBridge assumes a trusted local user
- **Malicious MCP clients** with full access to localhost — the server is intended for local agents; use firewall / tunnel controls for remote exposure
- **Third-party services** (Notion API, Stripe, Cloudflare) — report to those vendors per their programs
- **Social engineering**, spam, or support abuse
- **License / entitlement** bypass — commercial enforcement is separate from security response; see README (license server is not a current product surface)

## Auto-updates

Updates are delivered via **Sparkle** with EdDSA signatures (`SUPublicEDKey` in the app). Only install TheBridge from **official** channels listed on [kup.solutions](https://kup.solutions/notion-bridge) or this repository’s releases.

## License enforcement (not security response)

Online license validation is **not** implemented in the app today. Piracy and unauthorized redistribution are handled under **Terms of Service** and applicable law, not through this disclosure channel.
