# The Bridge — Privacy Policy

**Effective date:** [YYYY-MM-DD]  
**Provider:** [Legal entity name] ("we," "us")  
**Contact:** isaiah@kup.solutions

The Bridge is a local-first Model Context Protocol (MCP) connector that runs on your own Mac. It lets an AI client you authorize (for example, Claude or ChatGPT) operate your Notion workspace and your Mac on your behalf. This policy explains what data the connector handles, where it lives, and what — if anything — leaves your device.

## 1. Core principle: local-first

The Bridge runs as a process on your Mac. Tool execution (reading and writing files, controlling apps, querying Notion, running scripts) happens **on your device**. We do not operate a backend that stores your content, and your files, messages, screen contents, and app data are **not** sent to us.

## 2. Data the connector handles

- **Notion content.** When you ask the AI to read, search, create, or update Notion pages, databases, or comments, the connector calls the Notion API using a token you supply. That content flows between your Mac and Notion. We do not retain it.
- **Mac app and system control.** The connector can read and act on local resources you grant it — files, Calendar, Reminders, Notes, Mail, Messages, Contacts, the clipboard, the screen (capture/OCR), Accessibility data, and shell/AppleScript execution. This data is processed locally to fulfill your request and is surfaced only to the AI client you connected.
- **Credentials.** Passwords, API keys, and tokens you store through the connector are written to the **macOS Keychain** on your device. iCloud Keychain sync is **off by default** and only enabled if you explicitly opt in per credential. The credential-listing tool returns service and account **names only** — never secret values.
- **Connection metadata.** Operational data such as tool-call audit entries and health/telemetry status is kept locally to support security gating and troubleshooting.

## 3. What leaves your device

1. **Calls to third-party services you direct** — e.g., Notion (when you use Notion tools), GitHub, Stripe, or other integrations you enable. These go directly from your Mac to that provider under your own credentials and that provider's privacy terms.
2. **MCP traffic to your authorized AI client.** When you connect a remote client (Claude or ChatGPT) over the optional cloud relay, the request/response traffic for the tools you invoke is carried between that client and your local Bridge.
3. **Optional cloud relay (Cloudflare Tunnel).** To reach your Mac from a remote AI client, you may enable a Cloudflare Tunnel. This opens a **persistent outbound connection from your Mac** — it does **not** open inbound ports. The tunnel carries only MCP protocol traffic between the client and your local server; it is a transport, not a store. If you never enable the relay, the connector is reachable only locally.

We, as the connector provider, do **not** receive your Notion content, files, screen contents, messages, or credentials.

## 4. Authentication and access control

Remote access uses **OAuth 2.1 (Authorization Code + PKCE)**. A third-party Authorization Server (WorkOS AuthKit) issues access tokens; the Bridge acts only as a Resource Server and validates each token's signature, issuer, audience, and expiry locally against the Authorization Server's published keys (no token contents are sent to us). Access is **scope-limited** to the specific tool families you authorize, and unlisted tools are denied by default (allowlist, not blocklist).

Destructive or irreversible actions (e.g., deleting a Notion data source, deleting a credential) require an explicit **step-up authorization** carried in the OAuth token. The Bridge will not dispatch such an action without it.

## 5. Data retention and deletion

- Content processed to fulfill a request is **not retained** by us.
- Credentials persist in your macOS Keychain until you delete them (via the connector's delete tool or Keychain Access). Deletion is irreversible.
- Local audit/telemetry stays on your device under your control.

## 6. Children's privacy

The Bridge is not directed to children under 13 (or the applicable age in your jurisdiction) and is intended for use by the device owner.

## 7. Security

Credentials are stored in the macOS Keychain. Remote access is authenticated (OAuth 2.1 + PKCE), bearer tokens are validated fail-closed, and the cloud relay is outbound-only over TLS. No system is perfectly secure; you are responsible for safeguarding your Mac, your account credentials, and the AI client you authorize.

## 8. Changes

We may update this policy; the effective date above reflects the latest version. Material changes will be reflected at the published policy URL.

## 9. Contact

Questions or requests: **isaiah@kup.solutions**.
