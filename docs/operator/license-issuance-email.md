# License-Issuance Email Template

**Status:** v1.0 DRAFT — operator review required before wiring to live Stripe webhook.
**Owner:** PKT-910 (this doc) → consumed by PKT-911 / P3 Stripe webhook in `kup.solutions/workers/nb-fulfillment` (or equivalent fulfillment worker).
**Purpose:** Single source of truth for the post-purchase "Welcome to The Bridge" email sent to customers after a successful Stripe checkout.

---

## Token reference

The Stripe webhook should populate these tokens before sending:

| Token | Source | Example |
|---|---|---|
| `{{customer_name}}` | Stripe Checkout `customer_details.name`, fallback to email local-part | `Alex Rivera` |
| `{{license_key}}` | Issued by fulfillment worker on `checkout.session.completed` | `TB-3X9K-7P2M-Q4R8-W1Y6` |
| `{{version}}` | Current released version at time of purchase (from `appcast.xml` or Worker env) | `v3.6.0` |
| `{{download_url}}` | Signed R2 URL for the DMG, valid for 7 days | `https://thebridge.kup.solutions/download?token=…` |
| `{{onboarding_url}}` | Public marketing-site onboarding page | `https://thebridge.kup.solutions/onboarding` |
| `{{support_email}}` | Static; configurable via Worker env | `isaiah@kup.solutions` |

If any token resolves empty, the worker MUST hold the send and surface an error in the dashboard rather than ship an email with `{{...}}` literals.

---

## Email — Subject line

```
Your Bridge license — welcome, {{customer_name}}
```

---

## Email — Plain-text body

```
Hi {{customer_name}},

Thank you for purchasing The Bridge. Your commercial license is active.

═══════════════════════════════════════════════════════════════
  Your license key

  {{license_key}}

  Version covered: {{version}} (and all patch updates on the
  same minor line)
═══════════════════════════════════════════════════════════════

NEXT STEPS

  1. Download the app
     {{download_url}}

     (This download link is valid for 7 days. If it expires,
     reply to this email and we'll send a fresh one.)

  2. Install
     Open the DMG and drag "The Bridge" into /Applications.

  3. Activate
     Launch The Bridge. Open Settings → Security → License, paste
     your key, and click Activate. The Bridge validates the key once
     and then runs normally on this Mac.

  4. Onboarding & docs
     {{onboarding_url}}

LICENSE TERMS (the short version)

  • One license = one Mac, one named user.
  • You receive all patch updates on the v{{version}} minor line for life.
  • Upgrades to future major/minor versions are a separate purchase.
  • Moving to a new Mac? Deactivate the old one first in
    Settings → Security → License, or email {{support_email}}.
  • 14-day refund — reply to your Stripe receipt or email
    {{support_email}} within 14 days of purchase.

  Full terms: https://thebridge.kup.solutions/legal/commercial-license

SUPPORT

  Questions, issues, or feedback — reply to this email or write
  to {{support_email}}.

Thanks for supporting independent software.

— Isaiah
   KUP Solutions
   https://kup.solutions
```

---

## Email — HTML body

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Your Bridge license</title>
</head>
<body style="margin:0;padding:0;background:#f6f7f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Oxygen,Ubuntu,sans-serif;color:#1a1a1a;line-height:1.55;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f6f7f9;padding:32px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;background:#ffffff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,0.06);overflow:hidden;">
          <!-- Header -->
          <tr>
            <td style="padding:32px 32px 16px 32px;">
              <div style="font-size:14px;color:#6b7280;letter-spacing:0.02em;">The Bridge</div>
              <h1 style="margin:8px 0 0 0;font-size:22px;font-weight:600;color:#0f172a;">
                Welcome, {{customer_name}}.
              </h1>
              <p style="margin:12px 0 0 0;font-size:15px;color:#374151;">
                Thank you for purchasing The Bridge. Your commercial license is active.
              </p>
            </td>
          </tr>

          <!-- License key card -->
          <tr>
            <td style="padding:16px 32px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:10px;">
                <tr>
                  <td style="padding:20px 24px;">
                    <div style="font-size:12px;font-weight:600;color:#64748b;letter-spacing:0.06em;text-transform:uppercase;">
                      Your license key
                    </div>
                    <div style="margin-top:10px;font-family:'SF Mono',ui-monospace,Menlo,Consolas,monospace;font-size:18px;font-weight:600;color:#0f172a;letter-spacing:0.02em;word-break:break-all;">
                      {{license_key}}
                    </div>
                    <div style="margin-top:12px;font-size:13px;color:#64748b;">
                      Version covered: <strong style="color:#1a1a1a;">{{version}}</strong> (and all patch updates on the same minor line)
                    </div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Download CTA -->
          <tr>
            <td style="padding:16px 32px 8px 32px;">
              <h2 style="margin:0 0 12px 0;font-size:16px;font-weight:600;color:#0f172a;">Next steps</h2>
              <ol style="margin:0;padding-left:20px;font-size:15px;color:#374151;">
                <li style="margin-bottom:14px;">
                  <strong>Download the app.</strong><br />
                  <a href="{{download_url}}" style="display:inline-block;margin-top:8px;padding:10px 18px;background:#0f172a;color:#ffffff;text-decoration:none;border-radius:8px;font-weight:600;font-size:14px;">
                    Download The Bridge {{version}}
                  </a>
                  <div style="margin-top:8px;font-size:13px;color:#64748b;">
                    Link valid for 7 days. Reply if it expires and we'll refresh it.
                  </div>
                </li>
                <li style="margin-bottom:14px;">
                  <strong>Install.</strong> Open the DMG and drag <em>The Bridge</em> into <code style="background:#f1f5f9;padding:1px 6px;border-radius:4px;font-size:13px;">/Applications</code>.
                </li>
                <li style="margin-bottom:14px;">
                  <strong>Activate.</strong> Launch The Bridge. Open <em>Settings → Security → License</em>, paste your key, and click <em>Activate</em>.
                </li>
                <li style="margin-bottom:0;">
                  <strong>Onboarding & docs.</strong>
                  <a href="{{onboarding_url}}" style="color:#1d4ed8;text-decoration:underline;">{{onboarding_url}}</a>
                </li>
              </ol>
            </td>
          </tr>

          <!-- License terms summary -->
          <tr>
            <td style="padding:24px 32px 8px 32px;">
              <h2 style="margin:0 0 10px 0;font-size:16px;font-weight:600;color:#0f172a;">License terms (short version)</h2>
              <ul style="margin:0;padding-left:20px;font-size:14px;color:#374151;">
                <li style="margin-bottom:6px;">One license = one Mac, one named user.</li>
                <li style="margin-bottom:6px;">All patch updates on the {{version}} minor line for the lifetime of that version.</li>
                <li style="margin-bottom:6px;">Future major/minor upgrades are a separate purchase.</li>
                <li style="margin-bottom:6px;">Moving Macs? Deactivate the old one in <em>Settings → Security → License</em>, or email <a href="mailto:{{support_email}}" style="color:#1d4ed8;">{{support_email}}</a>.</li>
                <li style="margin-bottom:6px;">14-day refund — reply to your Stripe receipt or email <a href="mailto:{{support_email}}" style="color:#1d4ed8;">{{support_email}}</a> within 14 days.</li>
              </ul>
              <p style="margin:12px 0 0 0;font-size:13px;color:#64748b;">
                Full terms: <a href="https://thebridge.kup.solutions/legal/commercial-license" style="color:#1d4ed8;">thebridge.kup.solutions/legal/commercial-license</a>
              </p>
            </td>
          </tr>

          <!-- Support / signoff -->
          <tr>
            <td style="padding:24px 32px 32px 32px;border-top:1px solid #e2e8f0;">
              <p style="margin:0;font-size:14px;color:#374151;">
                Questions, issues, or feedback — reply to this email or write to <a href="mailto:{{support_email}}" style="color:#1d4ed8;">{{support_email}}</a>.
              </p>
              <p style="margin:16px 0 0 0;font-size:14px;color:#374151;">
                Thanks for supporting independent software.<br />
                — Isaiah, KUP Solutions
              </p>
            </td>
          </tr>
        </table>

        <!-- Footer -->
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;margin-top:16px;">
          <tr>
            <td align="center" style="padding:8px 16px;font-size:12px;color:#94a3b8;">
              KUP Solutions · <a href="https://kup.solutions" style="color:#94a3b8;">kup.solutions</a> · You're receiving this because you purchased a license for The Bridge.
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
```

---

## Implementation notes for the Stripe webhook

1. **Idempotency.** Key the email send on `checkout.session.id` to avoid duplicate sends on Stripe webhook retries.
2. **Order of operations.** Issue the license key and persist it to the licenses table **before** rendering and sending this email. The email must reflect a key that already exists.
3. **Download URL signing.** `{{download_url}}` should be a Worker-signed URL with a 7-day TTL, scoped to the DMG object key from `wrangler.toml`. The URL must validate on click against the customer's email or the session ID.
4. **Bounce / delivery handling.** If the email bounces, surface the failure in the operator dashboard with a "Resend" affordance — do NOT auto-retry on hard bounces.
5. **Test mode.** Stripe test-mode purchases should route to a separate "operator-only" template flagged with a `[TEST MODE]` subject prefix so the live template is never accidentally sent to a real-money inbox.
6. **Plain-text fallback.** Always send multipart/alternative with both bodies — some operator-side compliance contexts (e.g. screen readers, archived mail) prefer plain-text.

---

## Operator review checklist

- [ ] Confirm the support email address (`isaiah@kup.solutions`) is the desired customer-facing channel.
- [ ] Confirm the 7-day download URL TTL — extend or shorten as appropriate for the fulfillment worker's signed-URL policy.
- [ ] Confirm the legal page URL `https://thebridge.kup.solutions/legal/commercial-license` will exist before this email is wired live (PKT-911 dependency).
- [ ] Confirm Stripe test-mode prefix policy and operator-only test inbox.
- [ ] Send a test through the live pipeline to a personal inbox before flipping the webhook on for real customers.
