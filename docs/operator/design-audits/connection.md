# Connection Page — Design Audit

**Scope:** The merged **Connection** (singular) page = **Connections + Remote Access** unified into one section.
**Status:** New merged page in the locked 7-section sidebar (`Orders · Skills · Jobs · Tools · Security · Connection · Advanced`).
**Method:** `design:design-critique` rubric (First impression → Usability → Hierarchy → Consistency → Accessibility) applied against the live source.
**Source (READ-ONLY):**
- `NotionBridge/UI/Sections/ConnectionsSection.swift` (hero orb · transport card · integrations grid · active clients · lifecycle)
- `NotionBridge/UI/Sections/RemoteAccessSection.swift` (cloud hero · status/toggle card · security posture)
- `NotionBridge/UI/ConnectionsManagementView.swift` (**dead code** — not instantiated)
- `NotionBridge/UI/ConnectionSetupView.swift` (**dead code** — not instantiated)
- `NotionBridge/UI/StripeConnectionSection.swift` (**dead code** — not instantiated)
- `NotionBridge/UI/BridgeShell.swift`, `NotionBridge/UI/BridgeThemeV2.swift`, `NotionBridge/UI/BridgeTokens.swift`

---

## 0. What actually renders today (ground truth)

Wiring confirmed in `SettingsWindow.swift:232-243` (`detailContent` switch) and `SettingsWindow+Sections.swift:42-50`:

- **`.connections`** → `ConnectionsSection(...)` — renders, in order (`ConnectionsSection.swift:42-56`):
  1. `hero` — server-status orb (`Server running/stopped`, 50×50 orb, two stat tiles, restart/copy icon buttons) — lines 60-92
  2. `transportCard` — three transport tiles (Streamable HTTP / Legacy SSE / stdio) — lines 164-194
  3. `integrationsCard` — "Integrated tools" 2-up grid: **Notion + Stripe** tiles — lines 268-300
  4. `activeClientsCard` — connected-client list with relative timestamps — lines 425-450
  5. `lifecycleCard` — Launch-at-login toggle + Check-for-Updates / Restart buttons — lines 494-531
- **`.remoteAccess`** → `RemoteAccessSection()` — renders (`RemoteAccessSection.swift:168-200`):
  1. `hero` — cloud glyph + "Remote Access" + long blurb — lines 204-226
  2. `statusCard` — "Bridge Cloud Access" + Enable toggle (`.disabled(!cloudConfigured)`) + status row + Add-to-Claude.ai — lines 230-270
  3. `securityCard` — 3 posture rows (capability-scoped / passkey-gated / credentials-stay-local) — lines 450-473

**Dead code that must NOT inform the merge** (verified: zero call-sites outside their own definitions):
- `ConnectionsManagementView` — multi-workspace Notion list w/ add/rename/set-primary/remove. Real Notion management lives on the **Security/Credentials** page, not here.
- `ConnectionSetupView` — the *old* tunnel model (`tunnelProvider` Cloudflare/Tailscale/Manual + manual `tunnelURL` + manual **bearer-token Generate/Copy/Clear**, `ConnectionSetupView.swift:77-401`). Superseded by `RemoteAccessSection`'s WorkOS/cloudflared flow. **Do not resurrect its manual-bearer UI.**
- `StripeConnectionSection` — standalone Stripe key card + sheet. The Stripe surface that *actually appears* is the integrations-grid tile in `ConnectionsSection.swift:290-296`.

---

## Design Critique: Connection (merged)

### Overall impression

Two competently-built but **redundant and overlapping** pages. Both open with a full glass "hero" card that says roughly the same thing ("the Bridge endpoint, and how things reach it"), both carry their own status semantics, and the most load-bearing fact for an MCP connector — **am I reachable, and by whom, right now** — is split across two heroes, a transport card, an active-clients card, and a separate cloud status row. The merge's biggest win is collapsing **two heroes into one live status strip** and racking the rest as **Local clients** then **Remote access**. The biggest risk is the **dead cloud URL / Model-A "coming soon" toggle**, which today presents an interactive control that does nothing.

### Usability

| Finding | Severity | Recommendation |
|---|---|---|
| Two heroes (`ConnectionsSection.hero` orb + `RemoteAccessSection.hero` cloud) both occupy a full BridgeGlassCard and state status. After merge they collide. | 🔴 Critical | Replace both with ONE compact **status strip** (one row, ~52pt). Kill both hero cards. |
| Model-A "Enable Cloud Access" toggle is rendered but `.disabled(!cloudConfigured)` with `cloudConfigured = WorkOSConfig...isConfigured` → false on shipping builds (`RemoteAccessSection.swift:116, 246-250`). A live-looking switch that can't move reads as broken, not "coming soon". | 🔴 Critical | Demote to a non-toggle **"Cloud access — Coming soon"** state pill + one-line explainer. No switch affordance until PKT-810 lands. |
| **No real cloud URL exists yet.** `connectedMCPURL` is built from a persisted tunnel hostname that is never set in this state (`RemoteAccessSection.swift:357-361`); the blessed path is `mcp.kup.solutions/mcp`. "Add to Claude.ai" only appears when `displayState == .online`, which is unreachable while `cloudConfigured == false`. So the cloud half is **all chrome, no payload**. | 🔴 Critical | Show the **blessed directory-connector URL `https://mcp.kup.solutions/mcp` as static, copyable reference text** in Remote access, with a "Coming soon — enable in a future build" note. Don't gate the URL behind an unreachable `.online` state. |
| **Stripe tile** in the integrations grid (`ConnectionsSection.swift:290-296`) — Stripe is being CUT from the product. | 🔴 Critical | **Remove the Stripe tile.** Do not redesign around it. (See §Stripe disposition.) |
| `transportCard` (Streamable HTTP / Legacy SSE / stdio) is an *informational* 3-tile row styled like a selector but with "no radio/selection affordance" (its own comment, lines 151-162). Useful to power users, noise to everyone else. | 🟡 Moderate | Fold transport detail into the **Loopback MCP endpoint** card as a collapsed "Transports" disclosure or a single muted meta line; don't give it a full card. |
| `lifecycleCard` (Launch at login, Check for Updates, Restart Bridge) lives on Connections today but is app-lifecycle, not connectivity. | 🟡 Moderate | Relocate **Launch at login + Check for Updates** to **Advanced**. Keep only **Restart Bridge** reachable from the status strip (it already exists as an icon button, lines 87). |
| "Configure ports" deep-links to `.advanced` (lines 102-108) and "Manage credentials"/"Manage ↗" deep-link to `.credentials` (lines 274-276, 349-357) — but `.credentials` is being merged into **Security**. | 🟡 Moderate | Repoint dep-links to the new **Security** section; keep "configure ports" → **Advanced**. |
| Active-clients list has no empty-state CTA — when zero clients, it just says "No clients connected" (line 436). For a connector, that's the moment to teach setup. | 🟢 Minor | Empty state should point to the per-client config in **Local clients** ("Connect Claude Desktop / Claude Code →"). |

### Visual hierarchy

- **What draws the eye first today:** the 22pt "Server running / stopped" title in the orb hero (`ConnectionsSection.swift:76-78`). That is the right *fact* but the wrong *weight* — it's a 50×50 orb + 22pt headline + two stat tiles + two icon buttons consuming ~88pt of vertical for one boolean. Density tenet violated.
- **Reading flow:** currently Connections page = orb → transports → integrations → clients → lifecycle, then a separate page for cloud. The merged page must read top-down as **status → local → remote**, mirroring how trust narrows (loopback is trusted, cloud is gated).
- **Emphasis fix:** the single most important emphasis is **reachability + who's connected**. That belongs in the status strip (online dot + client count + last-seen), not buried in card #4 (`activeClientsCard`).

### Consistency

| Element | Issue | Recommendation |
|---|---|---|
| Card vertical rhythm | `ConnectionsSection` uses `VStack(spacing: 14)` + `.padding(20)` (lines 44, 51); `RemoteAccessSection` uses `VStack(spacing: 14)` + `.padding(18)` (lines 170, 175). | Unify to `spacing: 12`, `.padding(16)` for the merged page (denser, per global tenet). |
| Status-dot vocabulary | `ConnectionsSection` orb uses `ok`/`bad` only (line 62). `RemoteAccessSection.DisplayState` has a 5-color machine: ok/warn/warn/bad/fg3 (lines 83-91). Transport tiles add a *third* dialect: filled/hollow/dim dots (lines 228-241). | One dot vocabulary across the page: `ok` online · `warn` degraded/connecting · `bad` offline/error · `fg4` idle/not-configured. |
| Section labels | `ConnectionsSection` uses `BridgeCardLabel` (small-caps, `BridgeThemeV2.swift:114-123`) for "Transport", "Integrated tools", etc. `RemoteAccessSection` uses it for "Bridge Cloud Access" but its hero + posture rows use plain 14-18pt titles. | All card headers → `BridgeCardLabel`. Reserve large titles for the status strip only. |
| Dep-link primitive | `ConnectionsSection` uses TWO link styles: `BridgeDepLink` (line 274) AND a hand-rolled `Text("Manage") + Text("↗")` (lines 349-358). | Use `BridgeDepLink` everywhere; delete the hand-rolled variant. |
| Toggle tint | Lifecycle toggle tinted `BridgeTokens.ok` (line 548); cloud toggle untinted (lines 246-249). | Standardize: connectivity/enable toggles tinted `accent`; the running/granted *state* uses `ok` only on dots/pills, not switch tracks. |
| Divider primitive | `ConnectionsSection` draws `Rectangle().fill(hairlineFaint).frame(height:0.5)` (lines 341, 444, 512); `RemoteAccessSection` uses `Divider().background(hairline)` (lines 255, 459, 465). | Pick one — prefer the explicit `Rectangle` hairline at `hairlineFaint` for in-card rules. |
| Stripe brand color | Stripe tile hardcodes `BridgeServiceMarkTokens.stripePurple` (line 293) and dead `StripeConnectionSection` hardcodes `Color(red:0.463,…)` (line 57). | Moot — Stripe is being removed. Flag both for deletion. |

### Accessibility

- **Legibility floor (≥11–12px):** mostly compliant, but several captions sit AT or under the floor and should be watched: transport endpoint `10.5pt` mono (line 208), stat-tile label `10pt` (line 119), transport state pill `9.5pt` (line 257), status-badge meta. `RemoteAccessSection` leans on `.caption`/`.caption2` (lines 241, 494) which resolve to ~11/10pt — acceptable but at the floor. **Recommendation:** bump the `9.5pt`/`10pt` micro-labels to `11pt`; they carry live state and currently breach the floor.
- **Color contrast:** signal *text* tokens are appearance-adaptive and tuned for both grounds (`BridgeTokens.swift:98-115` — e.g. light-mode `okText #0A6442`, `badText #941F1F`). Good. But several places color *body* text with a raw signal fill on a tinted chip (e.g. transport pill `color` on `color.opacity(0.14)`, lines 255-263) rather than the `*Text` variant — risk of low contrast in light mode. **Use `okText`/`warnText`/`badText` for text-on-signal-chip, not the base `ok`/`warn`/`bad`.**
- **Hit areas:** icon buttons are 30×30 (`ConnectionsSection.swift:133`) — under the 44pt comfortable target but acceptable for a dense desktop utility; keep ≥28pt. The whole-row tap targets (active clients, transport tiles) are generous. The dead `ConnectionSetupView` header is a proper combined a11y element (lines 151-155) — good pattern to carry into the disclosure rows of the merged page.
- **State not by color alone:** transport dots already pair shape with color (filled/hollow/ring, lines 228-241) — keep that pattern for the status strip (dot + text label, never dot alone).

### What works well

- **`BridgeGlassCard` + `BridgeCardLabel` + `BridgeDepLink`** are a clean, consistent kit; both sections already compose them. The merge is a re-rack, not a rebuild.
- **`RemoteAccessToggleDecision`** (lines 34-70) is a genuinely good pure state-resolver — the `.comingSoon` and `.ignore`-on-revert cases encode real bugs already fixed. Preserve this logic when the toggle is demoted; it's the contract for the future live state.
- **Security posture card** (lines 450-473) is excellent trust-building copy (capability-scoped / passkey-gated / credentials-local). Keep it, but make it conditional/secondary until cloud is live.
- **Transport informational-not-selector** decision (the long comment, lines 151-162) is the right call — honest UI. Just give it less real estate.
- **Active-clients relative timestamps** (`just now / 5m ago`, lines 484-490) are exactly the "last-seen" signal the status strip needs.

### Priority recommendations

1. **Collapse two heroes → one status strip.** Online dot + "N clients · last seen" + Restart/Copy actions in a single ~52pt row. Kill `ConnectionsSection.hero` (60-92) and `RemoteAccessSection.hero` (204-226).
2. **Fix the dead-cloud problem honestly.** Demote Model-A toggle to a "Coming soon" pill; surface `https://mcp.kup.solutions/mcp` as static copyable reference; ungate it from the unreachable `.online` state.
3. **Delete Stripe.** Remove the integrations-grid Stripe tile (290-296); leave the grid as Notion-only (or a single Notion row). Flag the three dead files for removal.

---

## 1. The status strip (locked: top of page)

A single live row replacing both heroes. Height ~52pt; one BridgeGlassCard or a flush strip.

**Fields (left → right):**
- **Status dot + label** — `ok` "Online" / `bad` "Stopped" (server running boolean, `statusBar.isServerRunning`). Dot pairs with text (a11y).
- **Who's connected** — `"{statusBar.connectedClients.count} clients"` (line 83 data). If zero → "No clients" in `fg4`.
- **Last-seen** — most-recent client `connectedAt` → relative ("2m ago"); reuse `relativeTimestamp` (lines 484-490). Hidden when zero clients.
- **Calls today** — optional, `statusBar.totalToolCalls` (line 84) as a muted meta, demoted from a full stat tile.
- **Actions (trailing, icon buttons 28-30pt):** Restart Bridge (line 87) · Copy loopback endpoint (line 88, with check-confirm).

Drop the 22pt headline, the 50×50 orb, and the boxed stat tiles — they spend ~88pt on one boolean. The strip carries the same facts in one line.

## 2. Local clients (stacked under strip)

Trusted loopback surface. PKT-810 model: the loopback `127.0.0.1:{port}/mcp` endpoint is bearer-exempt for local clients (the static-bearer-only-for-non-loopback model — `MCPHTTPValidation.streamableHTTPBearerPhase`, `MCPHTTPValidation.swift:28,69-74`). State that exemption plainly so users understand local clients need no token.

- **Loopback MCP endpoint card** — `127.0.0.1:{ConfigManager.shared.ssePort}/mcp` (lines 39-40) as copyable mono text + Copy button. One muted line: "Local clients on this Mac connect with no token." Transport detail (Streamable HTTP / Legacy SSE / stdio, lines 164-194) folds in here as a collapsed "Transports" disclosure, NOT its own card.
- **Per-client config rows** — Claude Desktop, Claude Code: name + connected/last-seen + a "Configure" reveal showing the exact endpoint/snippet to paste. Empty state ("No clients connected", line 436) becomes the teach moment with these rows.

## 3. Remote access (stacked, below Local)

The cloud connector. Today gated (`cloudConfigured == false`).

- **Header:** `BridgeCardLabel("Remote access")`.
- **Directory connector URL:** `https://mcp.kup.solutions/mcp` as **static copyable reference** (NOT gated behind `.online`). This is the blessed cloud path.
- **Model-A state:** **"Cloud access — Coming soon"** pill (`warn`/`fg4`), NOT a disabled switch. One line: cloud sign-in not yet enabled on this build (PKT-810). Preserve `RemoteAccessToggleDecision` (34-70) for when it goes live.
- **Security posture** (lines 450-473): keep, but secondary/condensed until cloud is live — it describes a flow the user can't yet take.
- **Add-to-Claude.ai** (lines 389-431): hidden until a live tunnel hostname exists (current behavior) — correct; leave gated.

## 4. Stripe-card disposition

**Remove.** Stripe is being cut from the product.
- Delete the Stripe tile from the integrations grid (`ConnectionsSection.swift:290-296`). The grid becomes Notion-only — and since Notion management lives on **Security/Credentials**, the whole `integrationsCard` (268-300) likely reduces to a single "Notion — Connected · N tools · Manage ↗ (Security)" row in the status strip or a one-line card, not a 2-up grid.
- Flag dead `StripeConnectionSection.swift` (entire file) and `BridgeServiceMarkTokens.stripePurple` for deletion.
- Do **not** design any Stripe presence into the merged page.

## 5. Density

- Page padding `20`→`16` (line 51), inter-card spacing `14`→`12` (line 44). RemoteAccess matches (`18`→`16`, `14`→`12`).
- Two full hero cards (~80-90pt each) → one ~52pt strip: net ~120pt reclaimed above the fold.
- Transport: full card (~110pt) → collapsed disclosure inside Local card.
- Integrations 2-up grid (Notion+Stripe, ~150pt) → one Notion line (~36pt) after Stripe removal.
- Lifecycle card relocated to Advanced (~120pt off this page).
- Stat tiles (lines 113-126) → inline meta in strip.

## 6. Consistency fixes (carry-list)

- One status-dot vocabulary (see Consistency table).
- One link primitive: `BridgeDepLink` only; delete hand-rolled "Manage ↗" (349-358).
- One divider: `Rectangle @ hairlineFaint`; drop `Divider().background(hairline)`.
- All card headers → `BridgeCardLabel`.
- Text-on-signal-chip uses `okText`/`warnText`/`badText`, never base `ok`/`warn`/`bad`.
- Repoint deep-links: credentials → **Security**, ports → **Advanced**.

## 7. Accessibility floor

- Raise `9.5pt`/`10pt` micro-labels (transport pill 257, stat label 119) to ≥11pt.
- Keep dot+label pairing in the strip (no color-only state).
- Icon hit areas ≥28pt (currently 30, OK).
- Carry the combined-a11y-element pattern from `ConnectionSetupView` header (151-155) onto the disclosure rows.

## 8. Edge cases

- **Server stopped:** strip dot `bad` "Stopped"; Local endpoint shown but muted; client list empty.
- **Zero clients, server up:** strip "No clients"; Local rows show per-client "Configure" CTA.
- **Cloud not configured (today's default):** Remote = static URL + "Coming soon" pill; no switch; no Add-to-Claude.
- **Cloud live (future):** Model-A toggle re-enabled via existing `RemoteAccessToggleDecision`; `.online` reveals real `connectedMCPURL` + Add-to-Claude.
- **Light mode:** verify signal text uses adaptive `*Text` tokens (they do at the token layer; the gap is *usage* on chips).
- **Long client names / version strings:** truncate-with-reveal, don't shrink (global tenet); `clientName` already concatenates name·version (479-482) — give it `.lineLimit(1).truncationMode(.tail)`.
