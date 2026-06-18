# Privacy Policy — The Bridge

**Effective Date:** March 25, 2026
**Last Updated:** 2026-03-30

---

## 1. Introduction

This Privacy Policy describes how KUP Solutions ("we," "us," or "our") handles information in connection with **The Bridge**, a native macOS application distributed via direct purchase at [kup.solutions](https://kup.solutions). We are committed to transparency about our data practices — and the short version is: **your data stays on your Mac.**

---

## 2. What The Bridge Does

The Bridge is a native macOS menu bar application that acts as a local bridge between AI agents (such as Notion AI) and your Mac's capabilities. It runs a local MCP (Model Context Protocol) server on your machine and provides tools for file management, messaging, screen capture, accessibility automation, and more — all processed locally.

---

## 3. Data Processing Model

**The Bridge processes all data locally on your Mac.** There is no hosted backend, no cloud processing, and no intermediary servers operated by us.

**Local-only processing means:**

- All tool executions (file operations, screen captures, message reads, accessibility actions) happen entirely on your device
- No data from tool executions is transmitted to our servers — we operate zero servers
- The MCP server runs on `localhost` and is not network-accessible by default
- Your files, messages, clipboard contents, screen captures, and accessibility data never leave your machine through The Bridge

**Three categories of outbound network connections exist, all user-initiated:**

1. **Notion API** — When you configure a Notion integration token, The Bridge communicates directly with the Notion REST API (`api.notion.com`) to read and write Notion pages, databases, and comments. This connection is between your Mac and Notion's servers. We have no access to your Notion data.

2. **Stripe API** — If you use the optional payment execution tool, The Bridge communicates with Stripe's API (`api.stripe.com`) to process payment intents using tokenized payment methods stored in your macOS Keychain. Raw card numbers are never stored — only Stripe payment method tokens (`pm_` prefixed) persist locally.

3. **Cloudflare Tunnel (optional)** — If you configure a Cloudflare Tunnel for remote access, your MCP traffic routes through Cloudflare's network to reach your Mac. You own and control your Cloudflare account and tunnel configuration. We do not operate, monitor, or have access to your tunnel.

---

## 4. macOS Permissions

The Bridge requests the following macOS permissions (TCC grants) to function. Each permission is requested individually, and you can deny or revoke any permission at any time through System Settings:

| Permission | Purpose | Data Accessed |
|---|---|---|
| **Full Disk Access** | Read Messages history, perform file operations across your filesystem | Messages `chat.db`, user files |
| **Accessibility** | Inspect and interact with UI elements in other applications | AX tree (element roles, titles, positions) |
| **Screen Recording** | Capture screenshots and perform OCR text extraction | Screen pixel data (processed locally via Apple Vision) |
| **Automation** | Control other apps via AppleScript (Messages, Chrome, Finder) | AppleScript command execution in target apps |
| **Contacts** | Search your contacts by name, phone, or email | Contact records via CNContactStore |

**Screen Recording re-authorization:** macOS 15+ requires periodic re-authorization for Screen Recording access. The Bridge's Permission Manager will surface this when re-grant is needed.

**You are always in control.** Denying a permission disables the associated tools but does not affect the rest of the application.

---

## 5. What We Do NOT Collect

- ❌ **No telemetry.** We do not collect usage statistics, crash reports, analytics, or behavioral data.
- ❌ **No account creation.** The Bridge does not require an account with us.
- ❌ **No tracking.** No cookies, pixels, fingerprinting, or advertising identifiers.
- ❌ **No data transmission to us.** We operate zero servers that receive data from The Bridge.
- ❌ **No AI processing.** The Bridge does not contain or run AI models. It is a tool bridge — intelligence stays in the AI agent (e.g., Notion AI), not in our app.

---

## 6. Security Model

The Bridge implements a **3-tier security gate** for all tool executions:

- **Open tier** — Read-only operations (file reads, screen captures, search queries) execute immediately with no user interaction required.
- **Notify tier** — Write operations (file writes, shell commands, sending messages) trigger a macOS notification informing you of the action.
- **Request tier** — High-impact operations (shell commands, sending messages, payment execution) require explicit user confirmation before execution.

**Additional protections:**

- **Auto-escalation patterns** — Commands containing `rm`, `kill`, `sudo`, `chmod 777`, or pipes to `sh`/`bash`/`eval` are automatically blocked or escalated.
- **Forbidden paths** — Write access to `~/.ssh`, `~/.gnupg`, `~/.aws`, `.env` files, `/System`, and `/Library` is denied.
- **Audit log** — Every tool call is recorded in an append-only local audit log with timestamp, tool name, input summary, output summary, and duration. This log is stored locally and never transmitted.

---

## 7. Credential Storage

If you use the Credential Manager (CredentialModule), passwords and payment tokens are stored in your **macOS Keychain** — Apple's built-in encrypted credential storage. The Bridge uses standard `SecItem` APIs and does not implement its own encryption. Payment card numbers are tokenized via Stripe before storage — raw card numbers are never persisted.

---

## 8. Auto-Updates

The Bridge uses the **Sparkle framework** for automatic updates. Update checks connect to our update feed to check for new versions. The Sparkle framework may transmit your macOS version and app version during update checks. No other data is transmitted. You can disable automatic update checks in Settings.

---

## 9. Third-Party Services

| Service | Purpose | Their Privacy Policy |
|---|---|---|
| **Notion** | API integration for reading/writing Notion workspace data | [notion.so/privacy](https://www.notion.so/privacy) |
| **Stripe** | Primary payment processor for [kup.solutions](https://kup.solutions) checkout and for PaymentModule (tokenized payment methods) | [stripe.com/privacy](https://stripe.com/privacy) |
| **Cloudflare** | Optional tunnel for remote MCP access | [cloudflare.com/privacypolicy](https://www.cloudflare.com/privacypolicy/) |
| **Sparkle** | Auto-update framework | [sparkle-project.org](https://sparkle-project.org) |
| **Lemon Squeezy** | May appear as **merchant of record** for certain storefront or regional purchase flows on kup.solutions; your order confirmation or receipt identifies the processor | [lemonsqueezy.com/privacy](https://www.lemonsqueezy.com/privacy) |

We do not share, sell, or provide your data to any third party. The connections listed above are initiated by you or your configured agents, and the data flows directly between your Mac and the third-party service.

---

## 10. Children's Privacy

The Bridge is a developer and productivity tool and is not directed at children under 13. We do not knowingly collect information from children.

---

## 11. GDPR Compliance (European Economic Area)

If you are located in the European Economic Area (EEA), the following applies under the General Data Protection Regulation (EU) 2016/679 ("GDPR"):

**Legal basis for processing:** The Bridge does not collect or process personal data on our servers. All data processing occurs locally on your device under your control. To the extent any processing occurs (e.g., Sparkle update checks transmitting your app version), the legal basis is **legitimate interest** (Article 6(1)(f)) — specifically, delivering software updates to maintain security and functionality.

**Data controller:** For any data processed by The Bridge on your Mac, **you are the data controller**. KUP Solutions does not have access to, store, or process your personal data.

**Your rights under GDPR:**

- **Right of access** — We hold no personal data about you. Your purchase data is held by Lemon Squeezy (our Merchant of Record) under their own privacy policy.
- **Right to erasure** — Uninstalling The Bridge removes all locally stored configuration, audit logs, and cached data. No data persists on our servers because we operate none.
- **Right to data portability** — Your configuration file (`~/.config/notion-bridge/config.json`) and audit logs are stored in standard formats on your Mac and are fully portable.
- **Right to object** — You can disable Sparkle auto-update checks in Settings to stop the only outbound connection initiated by the Software itself.
- **Right to lodge a complaint** — You may contact your local Data Protection Authority.

**Data transfers:** The Bridge does not transfer your data to any country or jurisdiction. Network connections you initiate (Notion API, Stripe, Cloudflare) are governed by those services' respective data transfer policies.

**Data Protection Officer:** Given the nature of our processing (zero data collection), we have not appointed a DPO. For inquiries, contact isaiah@kup.solutions.

---

## 12. CCPA Compliance (California)

If you are a California resident, the following applies under the California Consumer Privacy Act ("CCPA") as amended by the California Privacy Rights Act ("CPRA"):

**Categories of personal information collected:** None. The Bridge does not collect, sell, share, or use personal information as defined by the CCPA. We do not collect categories of personal information enumerated in Cal. Civ. Code § 1798.140(v).

**Sale or sharing of personal information:** We do **not** sell or share your personal information. We have not sold or shared personal information in the preceding 12 months.

**Your rights under CCPA/CPRA:**

- **Right to know** — We collect no personal information. Your purchase information is held by Lemon Squeezy as Merchant of Record.
- **Right to delete** — Uninstalling The Bridge removes all local data. We hold nothing to delete.
- **Right to opt out of sale/sharing** — Not applicable; we do not sell or share personal information.
- **Right to non-discrimination** — We will not discriminate against you for exercising your CCPA rights.
- **Right to correct** — Not applicable; we hold no personal information to correct.
- **Right to limit use of sensitive personal information** — Not applicable; we do not collect sensitive personal information.

**Do Not Sell or Share My Personal Information:** The Bridge does not sell or share personal information. No opt-out mechanism is required or provided because no sale or sharing occurs.

**Authorized agents:** You may designate an authorized agent to make requests on your behalf by contacting isaiah@kup.solutions.

---

## 13. Changes to This Policy

We may update this Privacy Policy from time to time. Changes will be posted at [kup.solutions/privacy](https://kup.solutions/privacy) and noted in the app's release notes. Your continued use of The Bridge after changes constitutes acceptance.

---

## 14. Contact

For questions about this Privacy Policy or to exercise your rights under GDPR, CCPA, or other applicable privacy laws:

**Email:** [isaiah@kup.solutions](mailto:isaiah@kup.solutions)
**Web:** [kup.solutions](https://kup.solutions)
