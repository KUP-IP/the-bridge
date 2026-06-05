# The Bridge — Terms of Service

**Effective date:** [YYYY-MM-DD]  
**Provider:** [Legal entity name] ("we," "us")  
**Contact:** isaiah@kup.solutions

These Terms govern your use of The Bridge, a local-first Model Context Protocol (MCP) connector that runs on your Mac and lets an AI client you authorize operate your Notion workspace and your Mac on your behalf. By installing, connecting, or using The Bridge, you agree to these Terms.

## 1. What The Bridge is

The Bridge is software you run on your own device. It exposes tools an authorized AI client can call to read and act on your local resources (files, Calendar, Reminders, Notes, Mail, Messages, Contacts, clipboard, screen, Accessibility, shell/AppleScript) and your connected services (Notion, GitHub, Stripe, and others you enable). It is **not** a hosted service that stores your content.

## 2. Eligibility and your responsibilities

- You must be the owner or an authorized administrator of the Mac on which you run The Bridge, and of the accounts you connect.
- You are responsible for the AI client you authorize, the credentials you store, and every action you direct the connector to take.
- You will use The Bridge only for lawful purposes and in compliance with the terms of the services you connect (e.g., Notion, GitHub, Stripe) and with applicable law.

## 3. Authorization and scopes

Remote access uses OAuth 2.1 (Authorization Code + PKCE) via a third-party Authorization Server (WorkOS AuthKit). Access is limited to the scopes you grant; tools outside your granted scopes are denied. By granting a scope you authorize the corresponding tool family to act on your behalf.

## 4. Destructive actions and step-up consent

Some tools perform irreversible operations (for example, deleting a Notion data source, deleting a Keychain credential, running shell commands). These are gated:

- Locally, the connector applies a security tier and human-confirmation model.
- Remotely, a destructive tool call is authorized **only** by an elevated OAuth scope (step-up) present on the verified access token. Absent that scope, the call is refused.

You acknowledge that destructive actions you authorize may be **permanent and unrecoverable**, and you accept responsibility for them.

## 5. Credentials

Credentials you store are written to the macOS Keychain on your device (iCloud sync off by default). You are responsible for keeping them secure and for revoking them when appropriate. We do not receive or store your credentials.

## 6. Third-party services

The Bridge interoperates with third-party services at your direction. Your use of those services is governed by their own terms and privacy policies. We are not responsible for third-party services, their availability, or their handling of your data.

## 7. No warranty

THE BRIDGE IS PROVIDED "AS IS" AND "AS AVAILABLE," WITHOUT WARRANTIES OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT. We do not warrant that the connector will be uninterrupted, error-free, or secure, or that AI-directed actions will be correct or complete.

## 8. Limitation of liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW, WE WILL NOT BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES, OR FOR ANY LOSS OF DATA, PROFITS, OR GOODWILL, ARISING FROM OR RELATED TO YOUR USE OF THE BRIDGE — INCLUDING ACTIONS TAKEN BY AN AI CLIENT YOU AUTHORIZED. Our aggregate liability for any claim relating to The Bridge will not exceed the greater of the amount you paid for it in the prior twelve months or USD $50.

## 9. Indemnification

You agree to indemnify and hold us harmless from claims arising out of your use of The Bridge, the actions you direct it to take, or your violation of these Terms or applicable law.

## 10. Termination

You may stop using The Bridge at any time by disconnecting clients, revoking scopes, and uninstalling. We may suspend or terminate access for violation of these Terms. Sections 5–9 survive termination.

## 11. Changes

We may update these Terms; the effective date reflects the latest version. Continued use after a change constitutes acceptance.

## 12. Governing law

These Terms are governed by the laws of [jurisdiction], without regard to conflict-of-laws rules.

## 13. Contact

**isaiah@kup.solutions**
