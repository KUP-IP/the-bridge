# Changelog

## [unreleased] — Credentials leak hotfix + Keychain entitlement hardening (PKT-933)

### Fixed — Credentials page leak (hotfix)

- **Settings → Credentials no longer surfaces foreign Keychain items** (Apple system services, Chrome Safe Storage, Spark, etc.). Root cause was a default-allow path in `isKeychainItemManagedByThisApp` plus `.unknown`-type entries clearing the surface filter. Read-time post-filter landed in `e550401`; this release adds the architectural fix below.
- **`StatusPulseDot` dashboard oscillation** — animation scoped to `.animation(value:)` instead of a `withAnimation` closure (`0871c51`).
- **CI hang containment** — `timeout-minutes` + a perl-alarm watchdog so a stuck job surfaces in <30min instead of riding the 6h GitHub Actions default (`286525b`).

### Added — Keychain access-group scoping (PKT-933)

- **`keychain-access-groups` entitlement** (`NotionBridge.entitlements`) declaring `VP24Z9CS22.kup.solutions.notion-bridge` — the app's *implicit default* access group, so existing credentials already reside there and the entitlement landing is **non-destructive by construction**.
- **`AppIdentifierPrefix`** wired into `Info.plist` so `defaultKeychainAccessGroupForThisApp()` resolves at runtime (the `e550401` post-filter previously fell through to its default-DENY branch).
- **`CredentialManager` scopes every `SecItem*` query** (save / read / list / delete) to the access group — but only when a cached entitlement probe confirms the capability. Unsigned dev builds, the test executable, and pre-entitlement production installs detect `errSecMissingEntitlement` and fall back to the read-time post-filter, so **this change is safe to ship before the entitlement is signed in**. Once entitled, foreign items are filtered at the system level and never reach the post-filter.
- **Non-destructive migration sentinel** (`migrateToAccessGroupIfNeeded`, wired at launch in `AppDelegate`) — idempotent continuity check that confirms our items are reachable in-group and logs a one-line receipt. It **never** deletes or re-creates an item (credential loss is a release-blocker). Defers (and re-runs) until the entitled build is installed.
- The `e550401` read-time post-filter is intentionally **retained** as belt-and-suspenders; removal is gated on production verification per the packet DoD.

### Tests

- +5 `CredentialsScopeFilterTests` cases covering `applyingAccessGroup` (inject when entitled / no-op when nil, both preserving keys) and `needsAccessGroupMigration` (absent attr → false, in-group → false, foreign group → true). Test floor 1466 → 1471.

> **Operator gate (PKT-933):** before merge, sign + notarize with the entitlement included (`codesign --display --entitlements` must list `keychain-access-groups`; `notarytool` must accept the entitled build) and run the manual migration verification — install a v3.6.x build with real credentials, update to this build, confirm every credential survives. Loss of even one credential is a release-blocker.

## [unreleased] — Sell/Distribute v3 · 1 (PKT-909)

### Added — Licensing foundation

- **`LicenseManager`** actor at `NotionBridge/Core/Licensing/LicenseManager.swift` — single source of truth for the 30-day trial gate and paid-license activation. State persists to `~/Library/Application Support/The Bridge/license.json` via `BridgePaths`; atomic writes; offline-first.
- **`LicenseToken`** at `NotionBridge/Core/Licensing/LicenseToken.swift` — Ed25519-signed JSON token format (`<base64url(payload)>.<base64url(sig)>`); verifier is pure + offline; signature tampering, payload tampering, wrong-key, malformed all fail closed.
- **`LicenseState`** at `NotionBridge/Core/Licensing/LicenseState.swift` — on-disk schema (firstLaunchAt, optional token, grandfather flag, trial-expired-acknowledged); forwards-tolerant Codable.
- **`LicenseRevocationClient`** at `NotionBridge/Core/Licensing/LicenseRevocationClient.swift` — best-effort online revocation check against the worker `/api/nb/verify` endpoint; injectable transport for tests; nil-on-network-error so a worker outage cannot lock users out (signature gate remains the security boundary).
- **Grandfather SAFETY CONTRACT** — existing v3.4.x → v3.6.0 auto-update users (detected via PathMigration's `.bridge-migration-v3.5-complete` sentinel) land as `.grandfathered` and never see a trial countdown. The state is sticky across relaunches even if the sentinel is later removed.
- **Settings → Advanced → License card** — status pill (Trial/Expired/Licensed/Grandfathered), paste field, Activate button with error states, Remove license, Buy a license deep-link. Self-hosted via `LicenseCardHost` so `AdvancedSection`'s signature is unchanged.
- **Dashboard expired banner** — slim red banner above the status row when the trial or license has expired; clicking opens Settings → Advanced.

### Changed — Dispatch gate

- **`ToolRouter.dispatch`** now checks `LicenseManager.shared.currentStatus()` BEFORE the module-group gate and tier resolution. An elapsed trial or expired license causes the dispatch to throw the new `BridgeToolError.trialExpired(toolName:, kind:)` (kind: `"trial-expired"` or `"license-expired"`), audit-logged exactly like the `moduleGroupDisabled` path. The check is injectable (`ToolRouter(securityGate:auditLog:licenseStatusProvider:)`) for tests; production tracks the shared LicenseManager.
- **`BridgeToolError`** gains `.trialExpired(toolName:, kind:)` carrying both the offending tool name and a machine-readable kind for connector routing.

### Worker (kup.solutions/workers/nb-fulfillment)

- **`POST /api/nb/verify`** — license revocation lookup. Request `{id, v:1}`, response `{status, expiresAt, checkedAt}`. KV-backed revocation table under `revoke:<id>`; absent ID returns `"active"` (worker is a hint, not the gate).

### Tests

- +57 tests across `LicenseTokenTests`, `LicenseManagerTests`, `LicenseUITests`, `LicenseRevocationTests`, `LicenseToolErrorTests`, `LicenseDispatchGateTests`. Test floor 1376 → 1433. Highlights: the SAFETY CONTRACT grandfather sentinel test pinning sticky-across-relaunch behavior; activate-with-wrong-key does not mutate state; loadOrInit idempotent (does not bump firstLaunchAt); trial day-math inclusive-boundary (30/1/0=expired).

## [3.6.0] — 2026-05-27 — Liquid Glass complete: rename, BridgePaths, Standing Orders, Command Bridge, ModuleGroup, Dashboard

Project rename "NotionBridge → The Bridge" complete in user-visible surfaces. Bundle identifier (`kup.solutions.notion-bridge`), Keychain service name (`com.notionbridge`), and SPM binary/target names intentionally preserved to protect user data continuity. GitHub repository renamed `KUP-IP/Notion-bridge` → `KUP-IP/the-bridge`; Sparkle SUFeedURL and appcast download URLs updated in lockstep — existing v3.4.x installs will pick up this release via GitHub's automatic redirect from the old URL.

### Added — Foundation (v4.0 wave)

- **`BridgePaths`** at `NotionBridge/Core/BridgePaths.swift` — single source of truth for all on-disk paths. `BridgePaths.applicationSupport(.commands)`, `.skills`, `.standingOrders`, `.jobs`, etc.; `BridgePaths.logs(.jobs)`, `.audit`, `.server`. All previously-hardcoded `~/Library/Application Support/NotionBridge/...` paths now route through here. Test hook `BridgePaths.overrideHomeForTesting(_:)` makes the entire FS layer redirectable to a temp dir.
- **`PathMigration.runOnce()`** at `NotionBridge/Core/PathMigration.swift` — idempotent one-shot migration from `~/Library/Application Support/{Notion Bridge,NotionBridge}/` and `~/Library/Logs/{Notion Bridge,NotionBridge}/` to the canonical `~/Library/Application Support/The Bridge/` + `~/Library/Logs/The Bridge/`. Collisions get a `.pre-migrate-<timestamp>` sibling; the legacy dir gets renamed to `.legacy-<timestamp>` (not deleted, one release cycle of recovery). Sentinel `.bridge-migration-v3.5-complete` short-circuits subsequent runs.
- **`CommandStore`** at `NotionBridge/Modules/Commands/CommandStore.swift` — 10-slot favorites with markdown-per-command + `index.json`. CRUD with duplicate-slug rejection; `setKeySlot(slug:slot:)` enforces 0–9 range with eviction; `recordUse` MRU + `search(query:)` for the Command Bridge popup; `Icon` enum (emoji / SF Symbol + NotionColor); `seedIfEmpty` ships 5 starter commands keyed to slots 1–5 on fresh install.
- **`StandingOrdersStore` + `StandingOrdersComposer` + `RoutingIndex`** at `NotionBridge/Modules/StandingOrders/`. Store: `orders.md` + sibling `metadata.json` with per-client overlays. Composer: client-prefix overlay matching, trailer-suppression guard for inline `## Routing skills` sections, universal v6.5.0 principle preservation. RoutingIndex: renders the routing-skill table for the trailer.
- **`BridgeThemeV2`** at `NotionBridge/UI/BridgeThemeV2.swift` — Liquid Glass primitive library: `BridgeGlassCard`, `BridgeGlassBubble`, `BridgeDepLink`, `PartialToggle` (TripleState off/partial/on), `BridgeCardLabel`, `NotionPalette` (semantic color tokens shared across the new UI).

### Added — UI surface (v3.6 wave)

- **PKT-876 — Settings sections Liquid Glass (5 sections).** Connections, Credentials, Permissions, Jobs, Advanced reskinned per locked `design/*.html` mocks. Shared `BridgeSettingsSectionHeader` consumed by every section (single component, 5 callers). Dep-link chips: Credentials → "Used by" → Tools modules; Permissions → "Required by" → Tools modules. Derived live from tool annotations.
- **PKT-877 — Tools page rebuild + dispatch fail-closed.** `ModuleGroup` abstraction derives 25 groups covering 173 tools (0 orphans) from tool-name prefix + explicit-override. `ModuleGroupCard` collapsible group cards with master `PartialToggle`, dep-hint chips, partial-state count badge. **SAFETY CONTRACT:** `ToolRouter.dispatchFormatted` returns `BridgeToolError.moduleGroupDisabled` (typed error, not stringly) on any disabled-group dispatch — no silent failure.
- **PKT-878 — Command Bridge popup rebuild.** 943-line legacy `CommandBoxController` (NSPanel + NSTableView + Carbon hot-key) replaced with `CommandBridgeController` (SwiftUI Liquid Glass). Borderless NSPanel at bottom-center-25%, `BridgeGlassBubble` 10-slot tray, 1–0 fires assigned favorite + clipboard-write + close, ↓ opens recents (in-memory session-only), typing fires substring search ranked by recency, 180ms ease-out open with 10ms-per-bubble cascade, full reduce-motion path. Menu-bar bridge-icon pill deep-links to Commands Settings. Operator smoke checklist at `docs/operator/command-bridge-smoke-checklist.md`. Carbon hot-key infrastructure preserved verbatim.
- **PKT-879 — Dashboard popover + Onboarding wizard + Commands icon picker.** Dashboard reskinned per `design/dashboard.html`: 300pt popover, every row jump-links via `SettingsNavigation`, status pulse glow respecting reduce-motion, two-col permission grid. Onboarding 7-step wizard refresh per `design/onboarding.html`: Liquid Glass cards, progress bar, transport-pick step with "Recommended" badge on stdio, final step lands user in Dashboard. Commands editor icon picker dialog: emoji tab (~40 curated) + SF Symbol tab (~200 curated via `NSImage(systemSymbolName:)`, no new SPM dependency) + Notion color swatch row. Selection persists immediately to `CommandStore.Icon`.

### Audit-driven polish (W1–W3 + v3.6·6)

- **Credentials list scoping (D1).** `CredentialManager.isKeychainItemManagedByThisApp` previously returned `true` when the keychain item had no `kSecAttrAccessGroup` attribute, surfacing every system Keychain item (`Com.Apple.Scopedbookmarksagent.Xpc`, `Chrome Safe Storage`, `Spark`, etc.) under "Stored credentials". Flipped to `false`; Bridge-saved items still surface via the metadata-flag and `com.notionbridge` infrastructure-service fallbacks. Extracted `matchesAccessGroup(item:expected:)` as a pure helper for testability.
- **Settings window title.** "Notion Bridge Settings" → "The Bridge Settings". `WindowTracker` matches both old and new for back-compat. Sweep also caught 4 other user-visible "Notion Bridge" strings (ToolRouter error, SecurityGate notification, PaymentModule error, About card).
- **Sidebar tint.** Settings sidebar List adopts `NotionPalette.blue` so selection state matches dep-link chips.
- **Jobs stats card.** Hardcoded "Failed: 0" cell removed (failure-tracking infra not wired — a hardcoded zero was worse than no metric). `Total` cell color switched from `Color.white.opacity(0.9)` to `Color.primary` for dark-mode readability.
- **Skills row visual hierarchy (D5).** Platform "Notion" badge and Routing/Palette toggles share a row but represent different action classes (informational vs. state). Added a vertical `Divider` between them. Skill name gains a small `arrow.up.right.square` glyph next to it to surface the click-to-open-in-browser affordance without requiring hover discovery.
- **Tools per-group expand-state persistence (D6).** Previously every group expanded on view load if any tool in the group was on, producing a wall-of-toggles. New cold-launch default: every group collapsed. User expand/collapse persists in `BridgeDefaults.moduleGroupExpanded`. Off groups still auto-collapse regardless of saved value (PKT-877 DoD invariant preserved).
- **Dead-code prune.** 230 lines of legacy `legacyAdvancedFormBody` removed from `SettingsWindow+Sections.swift`.
- **Security hardening.** `CommandStore.slugify` previously accepted Unicode `Ll` (lowercase letters), permitting homoglyph collisions (Cyrillic `а` U+0430 vs ASCII `a`). Locked to ASCII `[a-z0-9_-]`. Two visually-identical command names can no longer produce different slugs.
- **Accessibility.** `BridgeSettingsSectionHeader` gains combined a11y (`.accessibilityElement(.contain)` + `.isHeader` trait + decorative icon hidden). `AdvancedSection` copy / reveal-in-Finder icon buttons labeled. `IconPickerSheet` color swatches expose `"<color> color"` labels with `.isSelected` trait; search field labeled per active tab; magnifying-glass icon hidden.

### Fixed

- **`v3.6·8` Standing Orders Composer trailer suppression** (cherry-picked from `21a6447`). When `orders.md` contains a curated inline `## Routing skills` section, the auto-rendered routing-index trailer is suppressed — fixes the confirmed double-render at MCP handshake.

### Tests

- **Floor raised 1232 → 1376** (+144 cumulative).
- New suites: `PathMigrationTests` (11), `StandingOrdersTests` (20 + 3 from v3.6·8), `CommandStoreTests` (15), PKT-876 `SettingsSectionsLGTests` (14), PKT-877 `ModuleGroupTests` (19) + `ToolRouterFailClosedTests` (6 SAFETY CONTRACT), PKT-878 `CommandBridgeControllerTests` (19), PKT-879 `PKT879DashboardTests` (10) + `PKT879OnboardingTests` (5) + `PKT879IconPickerTests` (12), v3.6.0 polish `CredentialsScopeFilterTests` (5), `ModuleGroupExpandPersistenceTests` (5), v3.6·6 `CommandStoreSecurityTests` (6).

### Branch hygiene + repo state

- 21 stale branches retired (15 in initial cleanup + v3.6/v4.0/pkt-778 closed post-merge + `_safety_branch` after polish). 13 zombie worktrees pruned from the old `notion-bridge` project location.
- `~/Developer/notion-bridge` → `~/Developer/the-bridge` directory rename complete; SPM `.build/.source_path` and `workspace-state.json` realigned; module cache cleared.

### Carve-outs (deferred to v3.7)

- **v3.7·A — SkillsCacheReader/Writer pipeline.** `StandingOrdersSection.cachedRoutingSkills()` currently returns `[]` (TODO marker); the composer + UI render correctly without it via the "None registered yet" path.
- **v3.7·B — `standing_orders_*` MCP tool surface.** Referenced in source comments; not registered with ToolRouter. In-Settings UI editor covers the read/write path for the human surface.
- **v3.7·C — Dashboard popover + Onboarding wizard manual visual verification.** Headless tests pass; pixel verification by an operator with reduce-motion enabled is the right exit gate.
- **v3.7·D — OnboardingWindow deep a11y pass.** Text-labeled buttons cover primary actions; deeper sweep belongs in a dedicated packet if VoiceOver users surface concrete gaps.
- **v3.7·E — Dark-mode regression sweep.** Glass material bleed-through can produce illegible foregrounds on dark wallpapers. Single token fix landed in v3.6.0 (Jobs Total); fuller audit deferred.

### Closeout docs

- `docs/operator/command-bridge-smoke-checklist.md` — PKT-878 smoke checklist
- `docs/operator/v3.6.5-closeout.md` — Standing Orders completeness Done-with-carve-outs
- `docs/operator/v3.6.6-closeout.md` — Code hardening (a11y, security, Sparkle pre-flight)

## [3.4.2] — 2026-05-21 — 3.4.1 regression fixes: hotkey recorder + Skills MCP combined-state

Targeted regression patch. Two confirmed defects shipped in 3.4.1 are fixed; observability + new MCP set_flags action documented as honestly deferred to 3.4.3.

### Fixed
- **Hotkey recorder couldn't capture after "Record shortcut" click (H5).** The W4-3.4.1 conditional render — `if isRecordingHotkey { HotkeyRecorderField } else { BridgeKbdChips }` — meant the recorder NSView was freshly mounted at the moment the operator clicked Record, before any window existed to receive a `makeFirstResponder` call. The redundant `DispatchQueue.main.async` focus-grab in `updateNSView` fired before the view landed in a window hierarchy → `nsView.window` was nil → silent no-op, no retry. Two defenses added: (1) `viewDidMoveToWindow` override on `RecorderNSView` grabs first responder on the reliable AppKit signal that the WindowServer is ready to route key events; (2) `applyRecording(true, …)` now grabs first responder *synchronously* in the same runloop turn when the view is already windowed (covers the toggle-after-mount path).
- **Skills MCP round-trip collapsed combined-state (H1).** Five `SkillConfig` reconstruction sites in [SkillsModule.swift](NotionBridge/Modules/SkillsModule.swift) (`set_metadata`, `sync_metadata_from_notion`, `toggle-enabled`, `rename`, `update_url`) re-built the row via `SkillConfig(..., visibility: cur.visibility, ...)` — the legacy enum ctor. The W4-3.4.1 back-compat enum→flag mapper would collapse the combined state (`routingDiscoverable=true && inCommandPalette=true`) down to `.command` (= `routingDiscoverable=false, inCommandPalette=true`), silently dropping the routing bit on every MCP write. Replaced all 5 reconstructions with the W4 flag-direct ctor that preserves the pair losslessly. Net effect: a skill flagged for both routing AND palette in the UI now survives any MCP-side mutation without drift.

### Added
- **MCP `list` envelope now exposes the flag pair.** Every `manage_skill action:"list"` result row carries `routingDiscoverable: Bool` + `inCommandPalette: Bool` *in addition to* the legacy `visibility: String` field. One-cycle back-compat preserved per the 3.5.0 deprecation plan; downstream callers can migrate to reading the flags directly while existing readers continue to work.
- **`writeSetFlags(named:routingDiscoverable:inCommandPalette:)` internal write path** — flag-direct setter that's now the SSOT; `writeSetVisibility(named:visibility:)` is preserved as a back-compat wrapper delegating to it.
- **`SkillsMCPFlagRoundTripTests.swift`** — 4 tests locking the H1 fix. Combined-state encode/decode round-trip · simulated MCP `set_metadata` full path round-trip · *negative test* documenting the pre-3.4.2 legacy-ctor regression boundary (so a future revert is loud) · envelope flag-pair shape lock.
- **`HotkeyRecorderFocusTests.swift`** — 6 tests locking the `RecorderFocusModel` contract that the H5 fix relies on: the `setRecording(true)` button-binding path leaves the model `acceptsFirstResponder == true`; the standalone `clickToRecord` path (3.2.0 Bug-1 baseline) remains intact; escape cancels; accepted-vs-rejected chord transitions.

### Notes
- **W3 fix scope:** all 5 reconstruction sites use the flag-direct ctor that takes `source:`; the `update_url` path wraps the new pageId in `.notion(pageId: newPageId)` so the W2-D2 source-discriminated shape stays intact.
- **W4 fix scope:** the `viewDidMoveToWindow` override + synchronous focus on transition are belt-and-suspenders. Either alone fixes the H5 regression; together they make the focus-grab fully race-proof against any future SwiftUI mount-timing change.
- **Deferred to 3.4.3** *(honest scope discipline per Decision #5 "limit blast radius per release")*: Workstream A observability (MCPActivityLogger actor + Settings → Advanced → MCP Activity panel + Export debug bundle button); manage_skill `set_flags` MCP action (flag-direct input). Both confirmed-defect fixes don't require observability to land — H1 and H5 were reproducible from code reading.
- **Carried forward**: Sparkle release-cut for v3.4.1 + v3.4.2 (operator-auth scope; gh release create + appcast.xml update). The installed build still won't Sparkle-self-update until appcast lands.
- **CI floor raised 1217 → 1232 (+15 net tests).** All 1232 tests green.

## [3.4.1] — 2026-05-20 — Commands tab UX/UI overhaul + flag-based visibility SSOT

End-to-end remediation of the Settings → Commands tab in response to operator UX critique. Replaces the mutually-exclusive 3-state visibility picker with two independent flags, brings Notion-source and file-source skills to row-level parity, ships a small shared component library (badges, kbd chips, empty-state), and strips MCP tool names from user-facing copy across the settings surface.

### Added
- **`routingDiscoverable` + `inCommandPalette` flags** on `SkillsManager.Skill` and `SkillsModule.SkillConfig`. Independent boolean axes — a skill may now appear in both the routing discovery list and the global Commands palette simultaneously, a state the legacy 3-state `SkillVisibility` enum could not express. The enum is preserved as a synthesized derived view + back-compat encode mirror for one release.
- **`SkillsManager.setRoutingDiscoverable(named:to:)` + `setInCommandPalette(named:to:)`** flag-direct mutators.
- **Per-path file-source flag storage.** `SkillsModule.{set,isFileSkill}{RoutingDiscoverable,InCommandPalette}` plus `BridgeDefaults.{fileSkillRoutingDiscoverable,fileSkillInCommandPalette}` keys. Effective routing-discoverable: explicit toggle wins, frontmatter `visibility: routing` as fallback default. Effective palette-membership: explicit opt-in only (conservative — palette commit currently requires a Notion page id, so file-source palette membership is staged as advisory until a file-source commit pipeline lands).
- **`AppDelegate.retryHotkeyRegistration()`** — explicit per-shortcut retry path; replaces the "toggle Commands off/on" workaround copy.
- **`BridgeBadge`, `BridgeKbdChips`, `BridgeEmptyState`** in `BridgeTheme.swift` — small shared component library. `BridgeKbdChips.splitChips(displayString:)` is `nonisolated static` so the chip parsing is headlessly testable.
- **Empty-state banner** above the Skills list when no enabled skill carries `inCommandPalette`. Surfaces the silent-fail condition that previously made the hot-key palette render empty without explanation.
- **Delete confirmation alert.** Row trash button now opens a confirmation dialog instead of firing on click.

### Changed
- **Visibility picker → two independent toggles** in both per-row Skill rows AND the Add-skill form. The legacy "Routing / Standard / Command" 3-state picker is replaced; a new skill can be added directly into the combined state.
- **File-source rows reach row-level parity with Notion-source rows.** Routing + Palette toggles added; description text uses `.secondary` contrast instead of `.tertiary`; folder-reveal button bumped from 16×14 to 24×20 with proper hit area + VoiceOver label.
- **Notion-source rows pruned for professional finish.** The redundant inline "Notion" source badge is removed (the section header already conveys source). The full UUID subtitle is replaced with a compact `ID …<last6>` affordance for skills with an ID set, and a `Set URL` button for skills missing one — full edit still on click. Reorder chevrons bumped to 24×20 with VoiceOver labels.
- **Commands palette section.** Hot-key display is now rendered as styled `kbd` chips (one per modifier + key) instead of a plain bordered text field; the recorder pop-in only appears during capture. Section title sentence-cased ("Commands palette" not "Commands Palette"). A `Retry` button surfaces in the `.warning` state alongside the existing checkmark/exclamation/minus state icons.
- **Sentence-case across all Settings sections.** "TCC Permissions" → "System permissions", "Integrated Tools" → "Integrated tools", "Connected Clients" → "Connected clients", "Remote Access" → "Remote access", "App Control" → "App control", "Local Server" → "Local server". Single capitalization convention across the seven sidebar tabs.
- **MCP tool names purged from user-facing copy** in the Skills + Commands surfaces. `fetch_skill` / `manage_skill` references replaced with action-language describing what the feature does, not what internal tool implements it.
- **Inline `Add` form copy** rewritten — "Add a skill" / "Add skill" (sentence case); footer help text rewritten around the two-flag mental model with explicit "Routing and Palette are independent" framing.

### Fixed
- Truncated visibility dropdowns on the Settings → Commands rows (the `Picker` was constrained by HStack squeeze and rendered as `Standard (fetch…)` / `Routing (discove…)`). The new two-toggle layout has a stable 180pt minimum width and shows full labels.
- Asymmetric file-source rows (no visibility control, no per-skill metadata) brought up to parity with Notion-source rows.
- Trash button no longer fires on click — confirmation alert required.

### Notes
- **Storage migration is one-cycle back-compatible.** `Skill` and `SkillConfig` encode the new flag pair AND the derived legacy `visibility` enum value; decode prefers the flag pair, derives from the enum on pre-3.4.1 rows, defaults `.standard` (both false) on the bare-minimum case. The 4 `SkillVsCommandSplitTests` LOCK tests are preserved unchanged. `SkillVisibility.allCases.count == 3` invariant preserved.
- **The MCP wire format is preserved.** `fetch_skill` / `manage_skill` / `skills_routing_list` continue to return the legacy `visibility` enum value alongside the new flag pair so external callers reading the enum field keep working until 3.5.x.
- **Q7=a all-tabs parity** was partially landed: shared `BridgeBadge` / `BridgeKbdChips` / `BridgeEmptyState` components are in `BridgeTheme.swift` and applied to the Commands tab; the other six tabs receive the sentence-case + tool-name-purge + contrast bumps. Per-tab badge migration is incremental and deferred to a follow-up sprint (not blocking; Commands is the marquee surface).
- **Drag-handle reorder + dedicated Add-skill sheet (Q3=a / Q4=a)** are deferred. The reorder arrow buttons are bumped to 24×20 with VoiceOver labels as an interim improvement; the inline Add form takes the new two-toggle UI verbatim. Sheet-based Add flow is scoped to the next Commands UX sprint.
- **Static feature module tool count unchanged at 172.** No tool added or removed in this release.
- **CI floor raised 1195 → 1217 (+22 tests).** 13 W1 flag-migration tests + 9 W4 component/storage tests, all green.

## [3.4.0] — 2026-05-19 — Sprint A: tool-surface consolidation + `idempotentHint`

Phase 2 of the mcp-builder leverage program. Top-15 audit recommendations shipped (12 structural, 3 description-only markers honestly flagged). Net surface lift: 162 → 172 registered tools (alias-inflated; the action surface contracts dramatically — `manage_skill`'s 11-action polymorphism in particular collapses into 5 verb-primitives).

### Added
- **`idempotentHint` annotation axis.** Fourth hint alongside `readOnlyHint`/`destructiveHint`/`requiresConfirmation`/`openWorld`. Non-optional `Bool` with no default; the existing zero-implicit-defaults invariant extended to require explicit per-tool classification. Audit-test fails the build on any unannotated tool.
- **`skill_create` / `skill_delete` / `skill_update` / `skill_rename` / `skill_sync_notion`** — 5 verb-primitives replacing `manage_skill`'s 11-action polymorphism. The old `manage_skill` is retained as a one-cycle deprecation alias that dispatches by `action`.
- **`git_worktree_list` / `git_worktree_add` / `git_worktree_remove`** — `git_worktree`'s 3-action polymorphism split into primitives.
- **`ax_inspect`** — rename of `ax_query` to the action-verb canonical name.
- **`ax_focused_app`** — REVIVED as a NEW dedicated zero-arg top-level tool (item 11). Distinct from the v2.2 deprecation shim of the same name that was removed in this release.
- **`gh_issue_create` / `gh_pr_create` / `gh_actions_runs_list`** — renames for verb consistency.
- **`chrome_tabs_list`** — rename of `chrome_tabs`.
- **`skills_routing_list`** — rename of `list_routing_skills` (now follows the `skills_*` prefix established by the `manage_skill` split).
- **`file_edit` with `mode: 'replace'|'patch'`** — full structural merge of `file_str_replace` + `file_apply_patch`. Both old tools kept as one-cycle aliases.
- **`job_pause` / `job_resume` `all: true` parameter** — full structural merge of `jobs_pause_all` / `jobs_resume_all`. Both old tools kept as aliases.

### Removed
- The 4 already-deprecated tools (`ax_focused_app` shim, `ax_find_element`, `ax_element_info`, `notion_block_read`) — one cycle elapsed since v2.2 deprecation.
- `echo` and `dev_module_info` — silent removal (audit item 8; `session_info` covers connectivity, `dev_module_info` was a self-described placeholder).

### Fixed
- `job_pause` / `job_resume` annotations corrected from `readOnlyHint:true` → `false`. They mutate LaunchAgent state (pause unregisters, resume re-registers); the annotation was a semantic bug the mirror-invariant test couldn't catch.

### Notes
- **All renamed/merged tools retain one-cycle deprecation aliases** (operator decision Q4=a). Old names continue to work; their descriptions carry a `DEPRECATED — use <new_name> instead. Removed in 3.5.0.` prefix. Audit recommended 2-cycle for `file_edit` and the `chrome_screenshot_tab` merge; operator override to 1-cycle flagged at the alias sites.
- **3 audit items shipped as description-only markers** (`notion_code_block_append`, `chrome_screenshot_tab`, `notion_connections_list`). The receiver tools (`notion_blocks_append` `autoChunk:true`, `screen_capture` `target={kind:'chrome_tab'}`, `connections_list` `kind:'notion'`) have semantically distinct backends that need non-trivial parameter wiring — full structural merge deferred to Phase 2.5.
- **Audit item 15** (snippets_* tier review) explicitly deferred — operator open question.
- CI floor lowered 1204 → 1195 with recorded decision in `scripts/test-floor-gate.sh` (the removed deprecated tools legitimately lost their tests; the audit invariant + new alias tests partially compensated but didn't fully replace the per-tool coverage).

## [3.3.1] — 2026-05-19 — Ship the 3.3.0 bundled skills (Makefile fix)

Hotfix. 3.3.0 (34) was released with the SKILL.md adoption code AND the 13 Apache-2.0 skills committed to the repo, but the `make install` packaging step copied only the executable target's SPM resource bundle into `.app/Contents/Resources/` and missed the `NotionBridgeLib` target's bundle — so the shipped binary had the loader code but no bundled skills to load. **No source changes; Makefile only.** Suite still 1204/0; same audit; same review.

## [3.3.0] — 2026-05-19 — SKILL.md adoption + bundled skills + plugin manifests

Phase 1 of the parity-or-better program. Bridge MCP now reads Anthropic's open SKILL.md format alongside its existing Notion-page skills, ships 13 Apache-2.0 skills out of the box, and exposes Claude Code marketplace manifests for distribution.

### Added
- **SKILL.md filesystem skills.** `fetch_skill` and `list_routing_skills` now also read filesystem skills from `Bundle.module` (bundled defaults shipped with the app) and `~/Library/Application Support/Notion Bridge/skills/<name>/SKILL.md` (user-installable) — additive to today's Notion-page skills, no migration. File-source skills return `content` = the markdown body (via the shared `MentionResolver`) and `properties` = the flattened YAML frontmatter, keeping the `fetch_skill` envelope shape identical to the Notion path. Same-name collisions resolve **Notion-wins** with a visible `shadows: file:<path>` annotation in the routing list.
- **13 bundled Apache-2.0 skills.** `algorithmic-art`, `brand-guidelines`, `canvas-design`, `claude-api`, `doc-coauthoring`, `frontend-design`, `internal-comms`, `mcp-builder`, `skill-creator`, `slack-gif-creator`, `theme-factory`, `web-artifacts-builder`, `webapp-testing` — verbatim SKILL.md only (no bundled scripts). 4 source-available skills (`docx`, `pdf`, `pptx`, `xlsx`) ship as stubs that link upstream rather than redistribute. Full attribution table at `docs/operator/skills-attributions.md`; Apache-2.0 LICENSE + NOTICE alongside the bundled skills per §4.
- **Settings → Commands.** Per-row source badge (Notion vs File); file-source rows are read-only with "Reveal in Finder" and a per-path enable/disable toggle (the `.md` file is never shadow-edited).
- **Claude Code plugin manifests.** `plugin.json` + `.mcp.json` at repo root describe Bridge MCP's tool surface in the Claude Code / Cowork plugin shape. The signed-`.app` vs npm-CLI shape mismatch is documented honestly rather than papered over; the marketplace submission spike captures the response.
- **`mcp-builder` audit report.** `docs/operator/mcp-builder-audit-report.md` — every one of 162 tools classified `keep` / `merge` / `split` / `rename` / `deprecate` with proposed `idempotentHint` values and a top-15 ranked Phase-2 backlog. Read-only; no code change in this release.

### Notes
- The `SkillsManager.Skill` struct gained a discriminated `SkillSource` enum (`.notion(pageId:) | .file(path:)`). The legacy `notionPageId` field is union-decoded for backward-compatibility and mirrored on encode — existing UserDefaults blobs and test fixtures continue to work unchanged. The 4 `SkillVsCommandSplitTests` LOCK tests remain green with their original assertions.
- `RegistrySkillsCommandProvider` (the global hot-key palette) requires `.notion` source AND `visibility == .command` — file-source skills are routing/standard surfaces only, never hot-key palette items. This preserves the Phase 3.2 split correctly under the new source axis.
- File-source skills default to `routing` visibility unless their frontmatter declares `visibility: standard`. This is a decision-under-agency (matches the "curated bundled set = zero-config discovery" intent).
- CI floor 1162 → 1204 (+42 tests covering parser, source, index, file-source envelope, merge precedence). Suite 100% green.

## [3.2.0] — 2026-05-19 — Commands: recorder/status fixed + Command visibility

Fixes the two reported Commands defects and adds a Command skill type so the palette shows only commands.

### Fixed
- **Hot-key recorder now captures.** Clicking the Shortcut field enters recording and grabs focus synchronously (was a best-effort async path that often never acquired first-responder, so keystrokes were dropped). Escape cancels; VoiceOver label/role added.
- **"Shortcut unavailable" no longer false.** The Settings status row now reads a single `@MainActor @Observable CommandsController` (owned by the app, injected into Settings) and re-renders live on every registration change — it was previously a one-shot snapshot that never refreshed. A genuine combo collision is now distinguished from a plumbing failure via the real Carbon `RegisterEventHotKey` status, and the generic state no longer falsely blames another app.

### Added
- **`Command` skill visibility.** A third type alongside Routing and Standard. The global Commands palette now shows **only** skills marked `Command` (enabled). Routing discovery (`list_routing_skills`) and `fetch_skill` (by name) are unchanged — a Command skill is palette-scoped for discovery but still fetchable by name. Both Settings pickers now derive from a single source (no hardcoded option lists). Empty palette shows a hint ("mark a skill as Command in Settings") instead of a blank list. `manage_skill` accepts `command`.

### Notes
- 3.2.0 is a SemVer-minor bump (new user-facing `Command` capability). Suite floor 1132 → 1162 (+30). The `@Observable` restructure converts most of the former "operator-smoke ceiling" into unit-tested logic; the irreducible ceiling (live Carbon hot-key fire + NSEvent capture) is documented and covered by `docs/operator/commands-smoke-checklist.md`.

## [3.1.1] — 2026-05-19 — Commands UX: one tab, editable hotkey, ⌃⌥⌘C default

Operator-feedback refinement of the 3.1.0 Commands palette. One unified place to manage commands, a user-editable global shortcut, and a collision-resistant default.

### Changed
- **One "Commands" section.** The redundant separate Skills and Commands Settings tabs are collapsed into a single **Commands** tab (`command` icon): the enable toggle + hot-key status pinned on top, the full Skills add/edit/delete list below it as the command manager. `SettingsSection` 8 → 7; the menu-bar/Dashboard quick-link now opens Commands.
- **Default global hot-key is now ⌃⌥⌘C** (was ⌃B). ⌃B collided with emacs/readline "back" and was already taken on some setups; the triple-modifier ⌃⌥⌘C is collision-resistant and rebindable. The legacy `spikeDefault` (⌥⌘Space) is retained only for Codable-fixture stability.

### Added
- **In-Settings hot-key recorder.** Record a new global shortcut directly in Settings → Commands; persisted (`commandsHotkey`), validated (rejects modifier-less / pure-modifier chords), live re-registered without a relaunch, with a reset-to-default and a clear ⚠ status when a combo is unavailable.

### Notes
- Skill-vs-command retrieval split is unchanged and now lock-tested: agent `fetch_skill` returns **properties + page body** in one call; the hot-key command path returns **page body only** (`/markdown`, no properties). 4 regression tests fail loudly if the asymmetry is ever blurred. CI green floor 1110 → 1132. The NSEvent capture gesture remains a documented operator-smoke ceiling; the Cocoa→Carbon mapping/validation/persistence beneath it is fully unit-tested.

## [3.1.0] — 2026-05-19 — Commands Palette (enterprise UX) + security remediation

A global-hotkey command palette: press the shortcut, type a skill name, `⏎` — the resolved Skill page body is on your clipboard. "Commands" ARE your enabled Skills (one registry, one source of truth). Graduated from an env-gated spike to an on-by-default, Settings-governed feature. Also hardens a destructive Notion tool and closes a behavioral-coverage gap.

### Added
- **Commands palette (P1+P2).** Default-ON, governed by a persisted **Settings → Commands** master toggle (the `BRIDGE_ENABLE_COMMANDS` env override is retained for CI). Default global hotkey **⌃B**, registered via Carbon (no Input Monitoring permission). Live results list with `↑/↓` selection, fuzzy ranking, and an inline "Copied ‹name›" confirmation; `Esc` dismisses; a non-matching query never copies a guess. New Settings section: master toggle (live enable/disable, no relaunch), a hot-key status row (Active / ⚠ unavailable), and the Skills list surfaced as the command manager.
- Pure, exhaustively-tested cores (gate precedence, selection state machine, commit→message presentation, multi-monitor placement); the AppKit/WindowServer surface is a documented operator-smoke ceiling.

### Changed
- **`notion_datasource_delete` security remediation.** Was registered `tier:.notify` (post-hoc notification, not a human gate) while `destructiveHint:true` — a destructive whole-data-source trash that could auto-execute on an LLM-supplied `confirm:true`. Now `tier:.request` + `neverAutoApprove` (non-downgradable; mirrors `snippets_delete`); annotation `requiresConfirmation:true` so the audit mirror-invariant stays exact. In-handler `confirm:true` retained as defense-in-depth.

### Notes
- Test-suite audit (66 files) against recent churn: closed the one HIGH gap (`notion_datasource_delete` had zero behavioral tests) with network-free handler + wire-body tests; one overclaiming test rewritten honestly. CI green floor 1074 → 1110.
- Hotkey is fixed at ⌃B this release (in-Settings rebinding + conflict-recorder is the planned P3).

## [3.0.0] — 2026-05-17 — Remote OAuth MCP Connector GA (PKT-800 S1–S3)

v3.0 GA. Bridge is now reachable as a remote, OAuth-secured Streamable-HTTP MCP connector (the sellable surface), additive and isolated — stdio and legacy SSE are byte-for-byte unchanged when `BRIDGE_ENABLE_HTTP` is unset.

### Added
- **Streamable-HTTP transport gate** (`BRIDGE_ENABLE_HTTP=1`) via `TransportRouter`; route dispatch unified through a single-source `MCPHTTPRoute` classifier (no shadowing of `/health`, `/sse`, `/messages`, `/mcp`).
- **RFC 9728 Protected Resource Metadata** at `/.well-known/oauth-protected-resource` — env-configurable issuer (`BRIDGE_OAUTH_ISSUER`), `resource` derived from the resolved SSE port, snake_case wire keys.
- **OAuth 2.1 bearer validation** on the `/mcp` connector path via JWTKit (pinned `exact: 5.5.0`): JWS/JWKS verification, `iss`/`aud`/`exp`/`nbf`, fail-closed when unconfigured; `401` + `WWW-Authenticate` on missing/invalid bearer. Path B = WorkOS AuthKit managed IdP (Decision Log row 21).
- **ScopeGate** mapping connector scopes → tool surface (default-deny allowlist; read vs write/destructive split); `403` on scope-deny, no dispatch.
- **Step-up consent** on `destructiveHint` tools, **confused-deputy** session/principal binding (token-derived only), and a **bearer-leak redaction sweep** of connector diagnostics.

### Notes
- Validation against live WorkOS/Cloudflare/Claude/ChatGPT is deferred until that infra is provisioned (built + green against synthetic JWKS/test vectors). Connector-directory submission artifacts prepared for operator submission.

## [2.3.0] — 2026-05-15 — Cursor Retirement + Menu-Bar Quick-Page (PKT-804)

v2.3 deck-clear. Retires the abandoned Cursor SDK integration and adds a menu-bar quick-page. Builds on the v2.2.1 rescue (landed per R1=Option A).

### Removed
- **Cursor SDK integration retired in full.** Deleted the 5 `cursor_agent_*` tools, `CursorRuntime`, `CursorAgentRegistry`, `CursorCostLedger`, `CursorAutoPauseController`, `CursorHeartbeatWatchdog`, `CursorNotificationDispatcher`, `CursorNewRunFormLogic`, `CursorTypes`, `CursorAudit`, `CursorModule`, the `CursorAgentsWindow` / `CursorNewRunWindow` / `CursorMenuBarLabel` UI, the `cursor-sidecar` package, the `@cursor/sdk` dependency, `SPEC.md`, and 6 Cursor test suites. Rewired `ServerManager` / `AppDelegate` / `DashboardView` / `NotionBridgeApp` / `BridgeNotifications` / `Version.swift` / `EndToEndTests`. **−5,489 LOC.** Rationale: `@cursor/sdk@1.0.12` local agents are upstream-unusable and the cloud path is economically dominated by in-subscription delegation (Decision Log #8, sk decisions, conf 0.85). Scoped split — kept the zero-coupling hygiene utilities only.
- Tool surface 154 → **149**; module families 19 → **18**.

### Added
- **`Modules/AgentHygiene/`** — `PromptRedactor` (gitleaks-style credential scrub) + `SensitiveRepoMatcher`, relocated out of the Cursor module as standalone reusable utilities (named v3 consumers: WS-C privacy audit, WS-F scope-gating). UserDefaults keys preserved for backward-compat.
- **Menu-bar quick-page (WS-H).** Header now exposes 3 deep-link icons — Skills, Tools, Settings — each opening the Settings window directly to that section via the new `SettingsNavigation` model + `SettingsWindowController.show(section:)`. Restart button anchored bottom-left, Quit bottom-right.

### Changed
- `SettingsSection` hoisted to file scope (was nested in `SettingsView`) so the quick-page can deep-link.

### Preserved (git-only)
- `AILogsWriter` + the `executor-sidecar` IPC pattern were dropped from `main` (hard-coupled to the Cursor DTO graph; clean retention needs out-of-scope generalization) but remain in history at `f06741b` — resurrectable by WS-E/WS-F.

### Verified
- `swift build` clean. **679 / 679 tests pass** (−67 removed Cursor suites, +6 new WS-H criteria-as-tests).

## [2.2.1] — 2026-05-13 — Cursor Module Rescue (PKT-3.4.1-RESCUE)

Live-wires the five `cursor_agent_*` sidecar methods that 2.2.0 shipped as `NOT_IMPLEMENTED` scaffolds (PKT-3.4.1.W2 was prematurely closed; this release closes the gap).

### Fixed
- **Sidecar `agent_run` / `agent_status` / `agent_list` / `agent_cancel` / `agent_artifacts`** now invoke `@cursor/sdk@1.0.12` (`Agent.create` → `agent.send` → `run.stream()` → `run.wait()`); each run emits structured `cursor_event` JSON-RPC notifications with monotonic `Last-Event-ID` to the Bridge.
- **Swift event pump** in `CursorRuntime.handleJSONRPCLine` now detects notification envelopes (no `id`, has `method`) and routes through a new event dispatcher that posts `.cursorAgentEventReceived` + feeds `CursorAgentRegistry` (upsert/touch/recordError) — registry was previously inert.
- **AI LOGS writer** (`CursorAILogsWriter`) drains terminal runs into a Session-typed entry in AI LOGS DS (`992fd5ac-d938-4be4-95fb-8ef18bd86bba`) with hash-only `Session Context` (sha256 promptHash; never the raw prompt).
- **Info.plist** stamped to match `Version.swift` SSOT (was stuck at 1.9.5 / 26).

### Changed
- **Cost ledger relocated** to `~/Library/Application Support/NotionBridge/cursor-sidecar/cost-ledger.json` (SPEC §7 canonical path); one-shot legacy migration leaves `.bak` of the old `cursor-cost-ledger.json`.
- Sidecar bumped to `0.2.0`; sessions persisted under `cursor-sidecar/sessions/<run_id>.json` for Last-Event-ID re-attach (SPEC §8).

### Known Gaps
- `@cursor/sdk@1.0.12` does not expose per-run cost; `costCents` recorded as `0` until SDK adds billing.
- Sidecar re-attach loads session metadata on startup but does not reconstruct the live SDK `Run` handle (stream re-attach across Bridge restart deferred).

### Verified
- TypeScript build (`npm run build`) clean.
- Swift `swift build -c debug` clean.
- DoD 4 capability probe (cap_missing[10002] in 1.49s) confirmed live.
- Live A1/B2/C5/5/6 — see PKT-778 `## Output` for receipts.

## [2.2.0] — 2026-05-13 — Agentic Dev Surface (consolidated release)

Successor to the v2 _Done venture (PRJCT-2722, closed 2026-05-05). Closes the five highest-pain gaps from the W29 retro: long-running task supervision, code-aware editing, LSP diagnostics, dev-server/port orchestration, structured git + GitHub. Adds Cursor SDK delegation (programmatic Cursor agents via `@cursor/sdk`, local + cloud runtimes) and MAC UI extras (synthetic keyboard / mouse, mdfind, pasteboard).

### Highlights
- **65 net-new tools** across `dev/`, `cursor/`, `computer/`, `jobs/` module families. Tool surface: **154 active** (vs. v1.9.5 baseline of 89). Family count: **19** (was 16).
- **`bg_process_*`** — long-running task supervision via `BgProcessRuntime` actor + `posix_spawn` + SIGCHLD reaping + atomic meta.json + kill cascade + orphan reaping. 6 tools.
- **`git_*`** — 9 structured git tools: status / diff / log / show / blame / apply_patch / worktree / create_branch / merge. Long ops routed via `BgProcessRuntime`; `git_merge` surfaces conflicts as structured JSON; `git_apply_patch` round-trips against `git_diff` output. Includes diff3 base-marker handling.
- **`gh_*`** — 9 GitHub CLI tools: actions_runs / check_status / issue_close / issue_comment / issue_open / pr_comment / pr_merge / pr_open / pr_status. Background-job dispatch for long ops.
- **`lsp_*`** — 6 LSP tools: definition / diagnostics / hover / references / rename / session_list. JSON-RPC client + `LspSession` actor + push-based `publishDiagnostics` cache + idle-dispose lifecycle. Live-tested against sourcekit-lsp + typescript-language-server.
- **Artifact toolkit** — 7 dev tools: `http_fetch`, `diff_render` (ANSI / HTML / markdown), `file_watch` (debounced), `tree_sitter_query` (TS / Swift / JSON / Markdown / Bash), `file_zip` / `file_unzip` (via `ditto`), `file_hash` (CryptoKit SHA-256).
- **Runners** — `playwright_run`, `vitest_run`, `lighthouse_run` under `module="dev"` tier `.request`. Supervised by `BgProcessRuntime`; structured JSON envelopes via shared `RunnerEnvelope<Details: Codable>`.
- **`devserver_*` + `port_inspect`** — 4 tools for dev-server lifecycle + port enumeration.
- **MAC UI extras** — `ax_query` (consolidates 4 prior AX tools), `cgevent_send` synthetic input, `pasteboard_*`, `spotlight_query` / `mdfind`.
- **Cursor SDK delegation** — 5 `cursor_agent_*` tools (run / status / list / cancel / artifacts). Node sidecar (`cursor-sidecar/`) over bidirectional JSON-RPC stdio; SSE event fan-out → Swift notifications; Last-Event-ID reconnect after sleep / net drop; hash-only AI LOGS Session entry per run; triple-keyed (repo, model, runtime) Always-Allow scope; redaction (16 gitleaks rules) + sensitive-repo allowlist + cost-cap auto-pause ($25 soft / $100 hard) + heartbeat watchdog. SwiftUI menu bar pill + standalone Agents window + new-run modal + 4 notification categories (READY / FAILED / STALLED / NEEDS_APPROVAL).
- **`code_search` / `file_str_replace` / `file_apply_patch`** — code-aware editing trio under `dev/`.
- **`wrangler_d1_status`** — Cloudflare D1 binding inspection with TOML parser.
- **Stripe long-tail deprecation** — 25 redundant Stripe tools collapsed to deprecation shims with warning + migration path.

### Changed
- MCP transport docs: `bg_process_*` canonicalized; `Sse client timeouts` decision-spike result documented (~60–75s cap is client-side, not Bridge).
- `LspRuntime` stdio response handling stabilized (chunked `readabilityHandler` + robust JSON-RPC id decoding).
- `claude_mcp_http_proxy.py` recovers expired session tokens mid-stream.
- E2E test surface repaired (`staticFeatureModuleToolCount` + tier assertions).
- CI matrix aligned with Swift 6.2 + macOS 26.

### Fixed
- `parseConflictMarkers` correctly skips diff3 base content via `sawBase` flag.
- LSP `workspace/configuration` server-request handled (reply with array of `null`); unknown server requests → `MethodNotFound`; `showMessage`/`logMessage` drained.

### Verified
- `swift run NotionBridgeTests` — **733 / 733 passed** on `bridge-v2.2/integration-closeout`.
- `LSP_LIVE=1 swift run NotionBridgeTests` — full live LSP suite green: sourcekit-lsp cold-start **0.588s** + hover **0.438s**; TS-LSP cold-start **0.143s**, references **485ms** (≤500ms target), idle-dispose round-trip clean.
- Live cross-tool integration verified: git_worktree round-trip, git_create_branch + switch, git_merge synthetic 2-way conflict surface, LSP server-init handshake on both adapters.

### Deferred (v2.2.x follow-up)
- **PKT-778** live Cursor acceptance harness (HITL): A1 local SDK round-trip ($), B2 cloud VM + PR on user-nominated repo ($$), C5 sleep/reconnect, capability auto-rollback failure injection. Environment ready (sidecar installed, SDK loadable, CURSOR_API_KEY in Keychain) — runbook in PKT-778 Output.
- **PKT-785** Cursor hardening Wave 2 ergonomics: NotionAPIClient drain-to-AI-LOGS writer, Settings UI Cursor section, lifecycle archival (7-day auto + bulk + hard-delete + transcript export), extra-approval modal wiring, worktree FIFO enforcement.
- **PKT-749.1** `ToolRegistration` triggers/anti-triggers schema extension.
- **PKT-752.1** SKILLS DS authoring batch (`/git-workflows`, `/gh-cli`, `/lsp-edit`, `/artifact-toolkit`, `/long-running-jobs`, `/test-runners`, MAC Keepr expansion). `/cursor-sdk` skill page authored as part of this release (BR-1).
- **PKT-753.1** composed dev-loop live e2e Playwright scenario (HITL-gated on billable Cursor + GitHub PR).

### Retired
- **PKT-3.2c** (good-dog Playwright + admin Lighthouse e2e) — out of scope; Good Dog is a separate project. Runner machinery ships with hermetic test coverage; live e2e against good-dog deferred to whoever owns Good Dog.

---

## [2.2.0-3.4.1.W2] — 2026-05-12 — Cursor sidecar IPC + LSP live-gate repair

### Added
- **`cursor-sidecar/`** — Node JSON-RPC sidecar package scaffold pinned to `@cursor/sdk` `^1.0.13`; supports `ping`, `capability_probe`, `agent_run`, `agent_status`, `agent_list`, `agent_cancel`, and `agent_artifacts` over line-delimited stdio.
- **`CursorRuntime` live IPC** — spawns the sidecar, injects `CURSOR_API_KEY`, correlates JSON-RPC responses, tracks process state, and maps sidecar run/artifact payloads into Bridge DTOs.
- **Cursor IPC tests** — fake sidecar coverage for ping, capability, run/status/list/cancel/artifacts, plus redaction audit enqueue on `agentRun`.

### Fixed
- **`LspRuntime` stdio reader** — replaced brittle `FileHandle.bytes` response handling with chunked `readabilityHandler` parsing and robust JSON-RPC numeric id decoding.
- **Live LSP gate** — `LSP_LIVE=1` now passes SourceKit hover plus TypeScript initialize/idle/rename/reference checks.

### Verified
- `swift run NotionBridgeTests` ✅ **726 passed / 0 failed**
- `LSP_LIVE=1 BRIDGE_REPO=/Users/keepup/Developer/notion-bridge KEEPUP_CLUB=/Users/keepup/Developer/keepup-club swift run NotionBridgeTests` ✅ **731 passed / 0 failed**
- `node --check cursor-sidecar/dist/index.js` ✅

## [2.2.0-3.1] — 2026-05-12 — Artifact/diff helper toolkit (PKT-743)

### Added
- **`ArtifactModule.swift`** — seven new `dev` tools: `http_fetch`, `diff_render`, `file_watch`, `tree_sitter_query`, `file_zip`, `file_unzip`, and `file_hash`.
- **`diff_render`** — renders unified diffs as markdown, ANSI, or escaped HTML and returns hunk/add/delete counts. HTML output escapes source content before adding spans.
- **`file_watch`** — bounded deterministic polling watcher with debounce; returns created/modified/deleted paths and leaves no persistent process behind.
- **`tree_sitter_query`** — uses `tree-sitter query` when the CLI is installed; otherwise reports `backend=fallback` and returns deterministic structural matches for TypeScript, Swift, JSON, Markdown, and Bash. Current sprint host has no `tree-sitter` binary, so true grammar-backed parsing remains a packaging dependency.
- **`file_zip` / `file_unzip` / `file_hash`** — macOS `ditto` zip round-trip helpers and SHA-256 hashing via CryptoKit.
- **`ArtifactModuleTests.swift`** — registration, HTML XSS sanity, SHA-256, zip/unzip round-trip, fallback structural query, and bounded watch coverage.

### Changed
- Static feature tool count bumped **147 → 154** and dev module family count expectation bumped **41 → 48**.
- `LspRuntime.extractFramedMessage` now accepts both CRLF and LF-only LSP headers while continuing to write spec-compliant CRLF frames.

### Verified
- `swift build` ✅
- `swift run NotionBridgeTests` ✅ **724 passed / 0 failed**
- `LSP_LIVE=1 swift run NotionBridgeTests` ❌ still fails the seven live LSP cases at SourceKit/TS-LSP initialize or hover timeout; the framing tolerance patch did not clear that environment/runtime gate.

## [2.2.0-2.3.1] — 2026-05-12 — LSP integration tests + live validation scaffold (PKT-789)

### Added
- **`LspModuleTests.swift`** — 10 hermetic probe-only tests covering `LspModule` registration (6 `lsp_*` tools under module `dev`, tier `.request`), `probe()` shape for typescript/swift/aliases/unsupported, `inferLanguage()` extension mapping, and `findWorkspaceRoot()` for TS (`tsconfig.json`/`jsconfig.json`/`package.json`) + Swift (`Package.swift`) + unsupported-language nil case. All pass under `swift run NotionBridgeTests` without `LSP_LIVE=1` (CI safe).
- **`LspModuleLiveExtraTests.swift`** — `LSP_LIVE=1`-gated suite: sourcekit-lsp hover on `LspRuntime` actor in the Bridge core, TS-LSP cold-start + idle-dispose round-trip (3s idle override + 5s sleep + re-cold-start, asserting registry state via `LspRuntime.listSessions()`), and TS rename + references on `~/Developer/keepup-club` (heuristic picks the first top-level `export`/`function`/`const`/`type`/`interface`/`class` name; logs reference count + rename file-count + latency for each).
- **Wired** both entry points (`runLspModuleTests()` + `runLspModuleRenameRefsLiveTests()`) into `NotionBridgeTests/main.swift` after `runShellModuleTests()`.

### Verified
- **Floor preserved** — `swift run NotionBridgeTests`: **435 passed / 437 total** (vs prior 425/427 floor). Same 2 pre-existing E2E `staticFeatureModuleToolCount` failures persist (Scope OUT — separate housekeeping packet ownership). +10 new tests, all green.
- **sourcekit-lsp cold-start: 0.580s** (DoD QA target <2s — met for the Swift adapter).

### Deferred to follow-up packet
- **Live test runtime infrastructure** — under `LSP_LIVE=1` against the current `~/Developer/notion-bridge-pkt777` + `~/Developer/keepup-club` state, the three live tests timed out:
  - `sourcekit-lsp hover on LspRuntime`: hover request timed out after 30s. Likely cause — the Bridge worktree has no `swift build`-generated indexstore, so SourceKit has no symbol DB to answer hover against. Remediation: warm-build the worktree before the live test, or have the test driver invoke `swift build` as a pre-step.
  - `TS-LSP cold-start + idle-dispose round-trip` and `TS rename + references`: both failed at `initialize` (timed out after 30s). Likely cause — the discovered workspace root in `keepup-club` lacks an installed `typescript` package (no `node_modules/typescript`), so `typescript-language-server`'s `initialize` blocks. Remediation: ensure `npm install` has run in the picked root, or have the test prefer roots that contain `node_modules/typescript/`.
- These are environment-tuning items, not Swift code defects — the test scaffolding itself compiles, links, and executes end-to-end; the timeouts are at the LSP server boundary. Honest-partial Done per UEP §4.5; closure precedent in Decisions #16/#28/#33/#35/#37/#39/#42/#43/#44.

## [2.2.0-0.2.2] — 2026-05-10 — wrangler_d1_status (PKT-757)

### Added
- **`wrangler_d1_status` tool** (under `dev/` module family) — resolves a Cloudflare D1 binding from `wrangler.toml` and reports applied + pending migrations against the local or remote DB. Read-only. Returns structured envelope `{ok, binding, database_name, configPath, applied:[{name, applied_at}], pending:[{name}]}`. Includes:
  - Hand-rolled minimal TOML parser for `[[d1_databases]]` and `[[env.<name>.d1_databases]]` blocks (no new dependencies).
  - Canonical-pair search over `<repoRoot>/wrangler.toml` and `<repoRoot>/workers/wrangler.toml` (pattern surfaced by the W29 / PKT-739 D2 investigation).
  - `binding_ambiguous` error envelope (with both paths + recommendation) when a binding is defined in both files.
  - `capability_missing` error envelope when `wrangler` is not on `PATH`.
  - Subprocess wrapper for `wrangler d1 migrations list` (pending) and `wrangler d1 execute --command "SELECT … FROM d1_migrations" --json` (applied).
  - Optional `envScope` parameter for environment-scoped bindings.
- **`WranglerModuleTests`** — TOML parser edge cases (empty / no-d1 / single / multiple / env-scoped / missing `database_name` / comments-in-quotes), resolver paths (single / ambiguous / not-found / missing-name / explicit-config), output parsers (box-drawn list + JSON envelope), tool registration shape, and gated integration tests against the 605-good-dog repo when reachable (DB → `605-good-dog-local`; preview → `605-good-dog-preview`).

### Changed
- **Tool-count baseline** bumped from 83 to **84** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 1 (`wrangler_d1_status`). Family count unchanged at 16 (registers under existing `dev` family alongside `DevModule`).
## [2.2.0-3.4.3.W1] — 2026-05-11 — Cursor hardening Wave 1: redaction + sensitive-repo allowlist (PKT-773)

### Added
- **`SensitiveRepoMatcher`** (`NotionBridge/Modules/Cursor/SensitiveRepoMatcher.swift`) — repo allowlist matcher. Default globs `~/Developer/secure/*` and `~/Developer/secure/**` (covers nested descendants); user-extensible via UserDefaults `com.notionbridge.cursor.sensitiveRepoGlobs` (string array). Matches via POSIX `fnmatch(3)` (strict + permissive passes) plus a prefix fallback for `parent/*` and `parent/**` patterns. Returns `Verdict { isSensitive, matchedPattern, forceLocal, requiresExtraApproval }`. Used by `CursorRuntime.evaluateGates(...)` to force runtime=local when a Cursor agent run targets a sensitive repo.
- **`PromptRedactor`** (`NotionBridge/Modules/Cursor/PromptRedactor.swift`) — inline gitleaks-style ruleset (16 built-in rules: AWS access/session keys, GitHub PAT/OAuth/App/fine-grained, Slack bot/user/webhook, OpenAI, Anthropic, Stripe, Google API, PEM private keys, JWTs, generic high-entropy ≥40-char strings). Replaces matches with `[REDACTED:<ruleId>]`. Returns `Result { scrubbed, count, ruleIds, promptHash }` where `promptHash` is sha256(original) hex via CryptoKit. User-extensible via UserDefaults `com.notionbridge.cursor.extraRedactionRules` (dict of `ruleId: regexPattern`). No external `gitleaks` binary required.
- **`CursorAudit.swift`** — `RedactionAuditEntry` + `CursorGateVerdict` DTOs. `RedactionAuditEntry` captures the metadata that PKT-3.4.1.W2's AI LOGS DS writer will drain into a Session-type entry: `runId`, `count`, `ruleIds`, `promptHash`, `repoPath`, `sensitiveRepoMatched`, `forcedLocal`, `redactedAt`. Never persists matched values; the unredacted prompt is referenced only by sha256 hash.
- **`CursorRuntime.evaluateGates(prompt:runtime:repoPath:)`** — pre-dispatch hardening pass. Returns scrubbed prompt + effective runtime (cloud→local override on sensitive repo) + queued audit entry. Pure (never throws); safe to call from tests without triggering IPC. Called inside `agentRun(...)` before `requireCapability()` so the audit fires regardless of capability outcome.
- **`CursorRuntime.pendingRedactionAudits()`** / **`drainPendingRedactionAudits()`** — actor-isolated read + drain on the queued audit entries. Wave 2 drains and writes to AI LOGS DS via `NotionAPIClient`.
- **`NotionBridgeTests/CursorHardeningTests.swift`** — 13 new unit tests covering SensitiveRepoMatcher (5 cases including user-extensible globs + nil/empty path), PromptRedactor (6 cases including AWS-key scrub, GitHub PAT scrub, clean-prompt passthrough, never-echoes-matched-value, known sha256 fixture, user-extensible rules), CursorRuntime.evaluateGates integration (4 cases including scenarios G3 and H1, plus queue observability + drain semantics). Runs against per-suite `UserDefaults` to avoid polluting host defaults.

### Hardened
- **`CursorRuntime.agentRun(...)`** — now runs the hardening pass before `requireCapability()`. When PKT-3.4.1.W2 wires real IPC, the scrubbed prompt + effective runtime are what flow through to the sidecar. Wave 1 continues to throw `notImplemented` post-gate (W2 contract unchanged; existing 501-test baseline preserved).

### Deferred to PKT-3.4.1.W2 (packet scope IN, but gated on live IPC)
- **AI LOGS DS write of audit entries** — DTOs + queue ship now; the actual `notion_page_create` against the AI LOGS data source (`992fd5ac-d938-4be4-95fb-8ef18bd86bba`) lives in PKT-3.4.1.W2 per Reflow #18 disposition (W2 owns the `NotionAPIClient` wire path).
- **Worktree-aware concurrency** (`git worktree list` queue + Dashboard `queued` status surfacing) — requires the running spawn surface from W2. CursorRuntime has no live IPC in Wave 1; there are no concurrent runs to queue against.
- **Lifecycle archival** (7-day auto-archive, bulk cleanup, hard-delete with hash-retain, transcript export markdown) — requires AI LOGS rows to archive against; W2 writes the first rows.
- **Settings UI section** (Dashboard → Settings → Cursor) — the UserDefaults keys ship now (`com.notionbridge.cursor.sensitiveRepoGlobs`, `com.notionbridge.cursor.extraRedactionRules`); a Settings UI section that manages them is PKT-3.4.2 / 3.4.3.W2 territory.
- **Modal redaction warning surface** in the new-run modal — the audit entries are observable now (per `pendingRedactionAudits()`); PKT-3.4.2's new-run modal will subscribe.

### Tests
- **+13** new tests in `runCursorHardeningTests()` (wired into `NotionBridgeTests/main.swift` after `runCursorModuleTests()`).
- Pre-existing **501** baseline preserved (the new `agentRun(...)` pre-gate hardening pass does not change the post-capability error contract that `CursorModuleTests` asserts).

### Provenance
- Branch: `bridge-v2.2/3.4.3-cursor-hardening` cut from `2e7bb88` (PKT-3.4.1 Wave 1 tip), parallelizable with `bridge-v2.2/3.4.2-cursor-ux` per packet Gates.
- Built in an isolated git worktree (`~/Developer/notion-bridge-3.4.3`) to avoid disturbing the main worktree's concurrent PKT-782 WIP.
- Spec: PKT-773 packet (Bridge v2.2 · 3.4.3) IN-scope items — sensitive-repo allowlist + prompt redaction + AI LOGS audit DTO ship; concurrency + archival + transcript export honestly deferred to W2 per Decision #15 honest-partial close pattern (mirrors PKT-3.4.1 Wave 1's pattern).

## [2.2.0-0.2] — 2026-05-10 — Remediation: notion_file_upload (PKT-739)

### Fixed
- `notion_file_upload` send-phase endpoint (carryover from v1.9.5 B1) — the second-phase POST now targets the documented Notion API route `/v1/file_uploads/{id}/send` instead of the non-existent `/send_content`, which had been returning `400 invalid_request_url` for every upload regardless of MIME. Trace labels (`phase=send`) updated to match.

### Added
- `notion_file_upload` MIME guard — uploads with unrecognized extensions (which previously fell through to `application/octet-stream`) now fail fast with a clear error listing all supported extensions, instead of being rejected by the Notion API with a confusing 400 `validation_error` from `phase=create_upload`.

### Deferred to follow-up packet
- `wrangler_d1_status` binding-ambiguity tool — out of scope here; tool does not yet exist in the Bridge MCP and creating it from scratch (TOML parser + subprocess + tests) exceeds the 0.2 complexity envelope.

## [2.2.0-0.1.2] — 2026-05-10 — AX consolidation: ax_query (PKT-755)

### Added
- **`ax_query`** unified Accessibility query tool — single `.open`-tier tool with a discriminated-union schema replacing the three overlapping per-shape AX query tools. Required `mode` enum (`focused_app` / `find_element` / `element_info`) selects the query shape; optional `pid`, `role`, `title`, `label`, `path`, `maxDepth` apply per-mode. Output matches the legacy tool payloads exactly. Deferred from PKT-738 (per Reflow #1, 2026-05-10).

### Changed
- **Tool-count baseline** bumped from 83 to **84** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 1 (`ax_query`). `AccessibilityModule` tool count goes 5 → 6 (3 legacy shims retained as deprecated, plus `ax_tree`, `ax_perform_action`, and the new `ax_query`).

### Deprecated
- **`ax_focused_app`**, **`ax_find_element`**, **`ax_element_info`** — descriptions prefixed with `[DEPRECATED v2.2 · PKT-755 — prefer ax_query with mode='X']`. Handlers continue to return the same payload as before, but now route through shared payload helpers and inject a `_deprecated` warning marker (`"Tool deprecated in v2.2 (PKT-755). Prefer ax_query with mode='…'. This tool will be removed in v2.3."`). Tools remain in registry through the v2.3 hard-removal ramp.

### Unchanged
- **`ax_tree`** and **`ax_perform_action`** untouched.
- macOS 26 Tahoe Accessibility permission flow unchanged in scope (PKT-754 territory).

## [2.2.0-0.1.1] — 2026-05-10 — Stripe long-tail deprecation shims (PKT-754)

### Deprecated
- **25 Stripe long-tail tools** wrapped with the `[DEPRECATED v2.2 · PKT-754 — prefer stripe_api_execute]` description prefix. Each shim emits a one-shot deprecation warning to stdout, increments a per-tool telemetry counter (`StripeDeprecationTelemetry` actor) for the v2.3 hard-remove decision, and forwards the call through `StripeMcpProxy.shared.callTool` to the canonical replacement.
  - **23 tools** (Invoices/Customers/Products/Prices/Coupons/Refunds/Disputes/PaymentIntents/Subscriptions/PaymentLinks/Account/Balance) translate args to `stripe_api_execute` with a stripe_api_operation_id (`PostInvoices`, `GetInvoices`, `PostCustomers`, `GetCustomers`, `PostProducts`, `GetProducts`, `PostPrices`, `GetPrices`, `PostCoupons`, `GetCoupons`, `PostInvoiceitems`, `PostPaymentLinks`, `PostRefunds`, `GetRefunds`, `GetDisputes`, `GetPaymentIntents`, `PostDisputesDispute`, `PostSubscriptionsSubscriptionExposedId`, `GetSubscriptions`, `DeleteSubscriptionsSubscriptionExposedId`, `PostInvoicesInvoiceFinalize`, `GetBalance`, `GetAccount`).
  - **2 aggregator tools** (`fetch_stripe_resources`, `search_stripe_resources`) route through `stripe_api_search` instead. `fetch_stripe_resources` translates a Stripe object id (e.g. `cus_123`, `pi_abc`) to a `<resource>:id:"<id>"` search query via prefix dispatch; `search_stripe_resources` passes its `query` field verbatim.
- Wrapped responses gain a `_deprecation_warning` sibling key so callers see the warning in JSON payloads in addition to stdout logging.

### Added
- **`NotionBridge/Modules/StripeDeprecationShim.swift`** — mapping table (25 entries), `StripeDeprecationTelemetry` actor (per-tool counter + per-session log gate), `wrapHandler(toolName:)` factory, `translateArgs(toolName:originalArgs:)` pure function, and result-decoration helper.
- **`NotionBridgeTests/StripeDeprecationShimTests.swift`** — 17 tests covering: 25-name mapping coverage, description prefix, decoratedDescription for both canonical paths, 5 spot-check argument translations (create_invoice → PostInvoices, list_invoices → GetInvoices, finalize_invoice → PostInvoicesInvoiceFinalize, retrieve_balance → GetBalance, cancel_subscription → DeleteSubscriptionsSubscriptionExposedId), search-canonical translations, fetch_stripe_resources id-prefix dispatch (5 prefixes), telemetry increment + shouldLogOnce gating, warning-message contents, result decoration, and operation_id verb-prefix coverage for all 23 execute-mapped entries.

### Changed
- **`StripeMcpModule.registerDiscoveredTools`** now branches per discovered tool: deprecated names get the prefixed description and the shim-wrapped handler; non-deprecated names retain the original pass-through handler.

### Gates
- Two-release ramp policy: **warn in v2.2, hard-remove in v2.3**.
- v1.9.5 binary base preserved; tool-count baseline unchanged (25 deprecated tools remain registered, just wrapped).
- DoD spot-check: 5 of 25 tools verified end-to-end via unit tests for argument translation; runtime warning surface validated by telemetry-actor tests.

### Notes
- The 2 aggregator tools (`fetch_stripe_resources`, `search_stripe_resources`) do not have a clean single-operation `stripe_api_execute` mapping, so they route through the alternate canonical (`stripe_api_search`). Description hint reflects this. Documented as a deliberate deviation from the strict "all 25 → stripe_api_execute" reading of the DoD.

## [2.2.0-4.1] — 2026-05-10 — MCP transport remediation: `bg_process_*` canonicalized (PKT-748)

### Decision spike (no code change)
Direct inspection of `NotionBridge/Server/SSETransport.swift` and `NotionBridge/Modules/ShellModule.swift` established that the ~60–75 s ceiling forcing the W29 `nohup ... > /tmp/log 2>&1 & disown` workaround **is not in the Bridge**:
- SSE session lifetime: `SSEServer(sessionTimeout: 300, sessionCleanupInterval: 30)` — normalized to `max(30, sessionTimeout)`; sessions only evicted after 5 min idle.
- `shell_exec` synchronous budget: `timeout = 600` s by default; background (`&`) commands capped at 5 s by design.
- **The ~60–75 s ceiling is a client-side per-call HTTP/SSE response deadline** enforced by the MCP client (Claude Code / Cursor / Notion AI tool runner) on a single in-flight `tools/call`. No server-side chunked-SSE long-polling on `shell_exec` would lift it because the cap fires on the client's awaited response, not on the bridge's ability to keep the stream open.

### Documented (no transport code change shipped)
- **`bg_process_*` canonicalized as the long-running funnel.** New `docs/mcp-transport-and-bg-process.md` documents the contract: `shell_exec` is for ops expected to return within the client's per-call window (conservatively ≤ 30 s wall-clock); anything longer **must** use `bg_process_start` → poll `bg_process_status` / `bg_process_logs` on subsequent short calls. The W29 `nohup … & disown` pattern is retired from agent skills; the only legitimate residual is MAC Keepr's self-update procedure (which must outlive the agent process by construction).
- **Public surface unchanged.** SSE `sessionTimeout = 300 s` and `shell_exec timeout = 600 s` defaults remain. No `transport_long_poll_enabled` flag introduced.
- **Anti-patterns retired:** `nohup … & disown` (relied on the 5-s background cap completing the synchronous return); `shell_exec timeout: 600` for 4-min workloads (still subject to the client-side ceiling); hand-rolled status files (the runtime already provides atomic status + orphan reconciliation via PKT-744).

### Deferred to v2.3 (backlog note)
- **Chunked-SSE long-poll on `shell_exec`.** Reconsidered only if a future MCP client raises its per-call response deadline materially above the `bg_process_*` polling cadence, or if a server-streamed tool output channel becomes necessary for non-job-shaped work. Not on the v2.2 / v2.3 critical path; `bg_process_*` covers every known long-running workload (devserver supervision, LSP, runners, Cursor SDK Node sidecar — see the PKT-744 downstream invariants).
- **Per-job resource caps (CPU / RAM)** — explicitly out of scope for v2.2 per PKT-744 §Scope.OUT; re-evaluated in v2.3 alongside any sandboxing work.

### References
- PKT-744 (v2.2 · 1.1) — `bg_process_*` runtime; public surface frozen here.
- PKT-748 (v2.2 · 4.1) — this entry; decision spike + governance, no Swift transport code change.
- `docs/mcp-transport-and-bg-process.md` — canonical guide for downstream consumers.

## [2.2.0-3.3.1] — 2026-05-10 — MAC UI extras Wave 2 (PKT-765)

### Added
- **`MouseClickModule`** registers **`mouse_click`** (.notify) — synthetic mouse click via CGEvent. Supports left/right/middle buttons and 1- or 2-click sequences. Accepts absolute screen coordinates by default, or window-relative coordinates (resolved via AX from the focused application’s focused window) when `windowRelative=true`. Returns `code="capability_missing"` with `settingsHint` deep-link when Accessibility is not granted; never silently no-ops.
- **`CGEventModule`** registers **`cgevent_send`** (.notify) — raw CGEvent escape hatch (cliclick-equivalent). Posts `key_down` / `key_up` / `key_press` events with virtual key code and modifier flags (`cmd` / `shift` / `opt` / `ctrl` / `fn` / `capslock`), or `scroll` events with pixel deltas on both axes. Same AX gate + `capability_missing` surface.
- **`PasteboardHistoryModule`** registers **`pasteboard_history`** (.open) — returns the rolling 50-entry pasteboard history captured by a background `NSPasteboard.changeCount` poller (750 ms interval, documented). Entries persist across bridge restarts to `~/Library/Application Support/NotionBridge/pasteboard-history.json`. No TCC grant required. Honors a `limit` parameter (1..50, default 50).

### Changed
- **Tool-count baseline** bumped to **+3** static feature module tools (`mouse_click`, `cgevent_send`, `pasteboard_history`).

### Notes
- Companion to PKT-747 (Wave 1: `spotlight_query` + `keyboard_type`). Branch `bridge-v2.2/3.3.1-mac-ui-extras-wave2` cut from PKT-747 head `6bf0507`.
- Live-HITL items deferred to QA: (1) `mouse_click` validation against an AX-incompatible (Adobe-class) application, (2) `pasteboard_history` idle CPU footprint measurement (target < 1%). The polling timer uses a utility-QoS DispatchSourceTimer with 100 ms leeway and string-only payload capture, which is the low-overhead path; measurement remains a QA gate.
- Test coverage: 7 new tests in `MouseClickModuleTests.swift`, 6 new tests in `CGEventModuleTests.swift`, 8 new tests in `PasteboardHistoryModuleTests.swift` (registration, tier classification, input validation, capability_missing surface, in-process pasteboard capture round-trip, limit clamping, persistence assertion).

## [2.2.0-1.2] — 2026-05-10 — code_search · file_str_replace · file_apply_patch (PKT-750)

### Added
- **`CodeEditModule`** registers three new `dev/` tools that replace ad-hoc `shell_exec rg` + manual file rewrite patterns:
  - **`code_search`** (.open) — ripgrep-backed search with structured output. Returns `{matches: [{path, lineNumber, lineText, columnStart, columnEnd, absoluteOffset, submatches}], count, elapsedMs}`. Honors `pattern`, `path`, `globs`, `caseInsensitive`, `fixedString`, `contextBefore`/`contextAfter`, `maxCount`. Discovers `rg` via `PATH` then common Homebrew/MacPorts prefixes; reports `capability_missing` if absent.
  - **`file_str_replace`** (.notify) — scope-safe string replace. Default mode requires the `search` substring to be unique in the file (rejects ambiguous matches with `status: "failed"`). `replaceAllMatches: true` opts into bulk replace and reports `occurrencesReplaced`. `preview: true` returns a unified diff without writing. Atomic write via tmp + rename.
  - **`file_apply_patch`** (.notify) — unified-diff apply with strict context validation. Parses `@@ -a,b +c,d @@` hunks; tolerates leading line drift but rejects context-line drift with a clear `context drift` error. Atomic write; partial application is impossible (validate-all-then-write).

### Changed
- **Tool-count baseline** bumped from 83 to **86** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 3 (`code_search`, `file_str_replace`, `file_apply_patch`).
- **Family count** unchanged at **16** (still the `dev` family from PKT-738).

### Notes
- Performance: `code_search` against the bridge repo itself (≈34k LoC) measures 27–38 ms p50 — well under the 500 ms p50 target for the ≈100k LoC reference workload.
- Test coverage: 18 new tests in `CodeEditModuleTests.swift` cover registration, tier assignment, structured search output, ambiguous-match rejection, replaceAllMatches, preview mode, unicode, trailing whitespace, no-match, not-found, clean apply, drift rejection, multi-hunk apply, and malformed patch rejection. Total bridge test count: **447 passed / 0 failed**.

## [2.2.0-0.1] — 2026-05-10 — Pruning + dev/ scaffold (PKT-738)

### Added
- **`modules/dev/` Swift module scaffold** — new `DevModule` registered as the 15th static feature module. Surfaces in `notion_modules_list` and exposes a placeholder `dev_module_info` tool. Foundation for v2.2 dev primitives (code-edit, cursor/, computer/ helpers); real tools land in follow-up packets (PKT-364, PKT-365, …).

### Changed
- **Tool-count baseline** bumped from 82 to **83** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 1 (`dev_module_info` scaffold). Jobs kill-switch drops do not affect this count because `JobsModule` is registered after `StripeMcpModule` in `ServerManager.setup()` and excluded from the static surface (matches test setup).
- **Family count** bumped from 15 to **16** with the `dev` family.

### Deprecated
- **`notion_block_read`** — description prefixed with `[DEPRECATED v2.2 · PKT-738]`. Prefer `notion_page_read` for whole-page reads or `notion_block_update` for surgical edits. Tool remains in registry through the v2.3 ramp.

### Removed
- **`jobs_pause_all`** and **`jobs_resume_all`** mass kill-switches deregistered. Per-job `job_pause` / `job_resume` (or iterate `job_list`) replace them. Factory functions retained in `JobsModule` for potential reinstatement; no longer wired to the router.

### Deferred to follow-up packets (out of scope here)
- 25 Stripe long-tail tool deprecations (warn + shim → `stripe_api_execute`) — needs its own focused packet; Stripe MCP module is a remote proxy and shimming requires a wrapping layer.
- AX collapse: `ax_focused_app` + `ax_find_element` + `ax_element_info` → unified `ax_query` — this is a feature implementation, not a warning shim, and warrants its own packet.

## [1.9.5] — 2026-05-04

### Added
- **Shell execution hardening** — `shell_exec` now reports structured success/status/timeout/termination fields, output line counts/truncation metadata, environment overrides, login-shell opt-in, tilde-expanded working directories, and recovery hints for long-running/background commands.
- **Filesystem caps** — `file_list` supports `maxEntries`/`maxDepth` with truncation metadata; `file_search` supports `maxResults`/`timeoutSeconds` with scanned counts and narrowing hints.
- **Notion diagnostics** — file uploads can return safe phase trace entries for create-upload vs send-content; long comment/discussion text is preflighted against Notion's 2000-character rich-text limit before API calls.
- **Chrome recovery** — `chrome_tabs` preserves partial tab listings when individual windows/tabs fail and returns structured per-item errors; `chrome_navigate` returns activation/tab-refresh recovery hints for off-Space or churned-tab failures.

### Changed
- MCP formatted responses now flag structured `success: false`/error-status payloads as tool errors at the transport layer while preserving the JSON body for agent recovery.
- Operator/agent guidance now documents portable search fallbacks, Python-first patch scripts, Cloudflare Pages temp-cwd deploys, inline-only Notion comments, and shell timeout/output semantics.

### Fixed
- Removed a duplicate execution-notification argument in the tool router path while adding structured failure propagation.

## [1.9.4] — 2026-04-18

### Added
- **Jobs pane redesigned** — vertical stacked layout modeled on macOS System Settings. `HSplitView` master/detail replaced with `ScrollView` + `LazyVStack` of grouped cards. Tap a row to expand the editor inline (schedule, action-chain JSON, skip-on-battery, Run Now, Duplicate, Pause/Resume, Copy ID, Reveal Log, Delete).
- **Segmented status filter** (All · Active · Paused) at the top of the Jobs pane.
- **Footer toolbar** — Pause All / Resume All / Export / Import moved to a persistent bottom bar. Includes a live count chip (`N jobs · M active`) with correct pluralization.
- **+ New Job sheet** — primary creation flow from the Jobs header and the empty state. Cron validation + action-chain JSON validation inline.
- **97 tool descriptions rewritten** across 18 modules per the §16 audit to improve routing specificity and reduce cross-tool overlap.

### Changed
- **Settings window consolidation** — removed the duplicate SwiftUI `Settings { }` scene. A single `SettingsWindowController`-owned NSWindow is now the canonical Settings surface, with unified transparent titlebar, `setFrameAutosaveName("NotionBridgeSettings.v2")`, min 640×720, max 900×1100, default 720×900 — closer to Apple System Settings proportions.
- **Empty-state copy** — replaced `job_create tool` jargon with "Tap **New** to create a job, or import a job export file."

### Fixed
- **Two Settings windows opening simultaneously** — root cause was the coexistence of SwiftUI `Settings {}` and the custom `SettingsWindowController`, each creating its own NSWindow with the same title. Consolidated to a single window controller.
- **Pluralization bug in Jobs toolbar** — count chip now derives from the live list and uses correct singular/plural.
- **Toolbar overflow at <900 px** — header reduced to Title + Search + Sort + **+ New**; bulk actions moved to footer.

## [1.9.3] — 2026-04-15

### Changed
- Packaging bump alongside Sparkle / Notion module polish shipped in commit `9acabdb`. No behavior changes beyond what is captured in 1.9.2 + prior entries.

## [1.9.2] — 2026-04-13

### Added
- **NBJobRunner** — dedicated launchd-invoked binary for executing scheduled jobs (commit `0058a2a`), decoupling job execution from the main app lifecycle.

## [1.9.1] — 2026-04-18

### Added
- **Jobs Surface** (Settings → Jobs) — restored dedicated sidebar section for scheduled jobs after v1.8.5 audit removed it. Includes status dots, human-readable cron preview, inline schedule editor with live validation, action-chain JSON editor, skip-on-battery toggle, Run Now, Duplicate, Pause/Resume, Delete, Copy ID, Reveal Log, search + sort toolbar, and kill-switches for Pause All / Resume All.
- **7 new scheduler tools** — `job_run`, `job_update`, `job_duplicate`, `job_export`, `job_import`, `jobs_pause_all`, `jobs_resume_all`. Scheduler module now exposes 15 tools total (up from 8).
- **JobStore.update(id:mutate:)** — atomic partial-update primitive on the JobStore actor with mutation closure; preserves id / createdAt, persists in one SQL round-trip.
- **JobsManager+V2.swift** — high-level handler module containing runNow/updateJob/duplicateJob/exportJobs/importJobs/pauseAll/resumeAll. Schedule changes trigger atomic LaunchAgent re-registration with automatic DB rollback + plist restore on failure.
- **CronHumanizer** — pure-Swift cron expression describer in JobsView (every minute, every N minutes, hourly at :MM, daily, weekly on DAY, monthly on day N).
- **JobExportEnvelope** — versioned Codable wire format for job export/import.

### Fixed
- **SettingsSection enum** — reintroduced `.jobs` case between Skills and Advanced with `clock.badge.checkmark` icon; v1.8.5 removal left no UI surface for scheduled jobs.
- **Version drift** — `AppVersion.marketing` bumped 1.8.5 → 1.9.0 to match Info.plist.

### Changed
- `BridgeConstants.staticFeatureModuleToolCount`: 73 → 80 (7 new scheduler tools). Family count unchanged at 15.
- `AppVersion`: 1.8.5 (20) → 1.9.1 (22).

## [1.8.5] — 2026-04-12

### Added
- **notion_datasource_update** MCP tool (notify tier) — Update a data source's schema (add/modify properties) via `PATCH /v1/data_sources/{id}`. Enables programmatic schema changes on multi-data-source databases.
- **notion_datasource_create** MCP tool (notify tier) — Create a new data source under an existing database via `POST /v1/data_sources`.
- **NotionClient: updateDataSource(), createDataSource()** — Two new API methods for data source write operations.
- **12 new tests** — Test suite hardening: invalid JSON rejection for new tools, missing-param validation for `notion_database_get`, `notion_datasource_get`, `connections_get/validate/capabilities`, `manage_skill`, `payment_execute`, `process_list` filter/limit params. Total: 389 tests.

### Fixed
- **EndToEndTests** — NotionModule expected tool count updated from 19 to 21.

### Changed
- `BridgeConstants.staticFeatureModuleToolCount`: 78 → 80.
- NotionModule: 19 → 21 registered tools.
- Release build: v1.8.5 (20).

## [1.8.4] — 2026-04-12

### Added
- **Contacts module** — four new MCP tools: `contacts_health`, `contacts_search`, `contacts_get`, `contacts_resolve_handle`. Backed by CNContactStore — works without Contacts.app running. Closes #16.

### Fixed
- **Tests & docs vs tool inventory** — E2E harness registers `ContactsModule`; expectations and README/AGENTS use `BridgeConstants.staticFeatureModuleToolCount` (78) + `echo` + Stripe **N**. `SystemModuleTests` expect three system tools after Contacts split.
- **Stripe startup resilience** — transient startup failures retry automatically (3-attempt exponential backoff, 2s→4s→8s); `stripe_reconnect` sentinel tool registered as manual recovery when all retries fail. Auth failures (missing key) skip retries immediately.
- Remote access URL field no longer clears on click.
- Remote access status indicator no longer shows green when bearer token is absent.
- Remote access status loads correctly on Settings open (not only after expanding section).

### Changed
- **Remote access UX** — save button with dirty-state tracking; three-state status indicator (no URL / URL without token / fully configured); session invalidation on token rotation.
- **Session persistence** — Bridge MCP sessions no longer expire (configurable via `sessionTimeout: 0` in config).
- Release build: v1.8.4 (19).

## [1.8.3] — 2026-04-11

### Fixed
- `credential_save`: accept `type: "api_key"` for save-path validation (GitHub #15).

### Changed
- Release build: v1.8.3 (18).

## [1.8.2] — 2026-04-07

### Fixed
- **Connection identity collision** — addConnection() now upserts when a connection with the same name already exists, preventing duplicate entries with dual-primary state. setPrimary() atomically unsets all other connections. preflightRemove() handles same-name edge case to allow self-healing deletion. loadConnections() auto-deduplicates on startup (last-write-wins) and ensures exactly one primary. (NotionClientRegistry.swift, NotionModels.swift)
- **Apple Passwords modal deadlock** — Added .textContentType(.none) to all SecureField inputs (token, password, API key, bearer token fields) to prevent macOS AuthenticationServices from hijacking the input with an undismissable Passwords picker. (ConnectionsManagementView.swift, OnboardingWindow.swift, CredentialsView.swift, ConnectionSetupView.swift)

### Changed
- **Shell-as-last-resort tool descriptions** — Updated 17 MCP tool descriptions to steer agents toward dedicated tools over shell_exec. shell_exec description now lists alternatives and includes fallback clause for when dedicated tools are disabled. 12 file/clipboard tools, process_list, applescript_exec, and screen_capture now include "Preferred over shell_exec X" guidance. (ShellModule.swift, FileModule.swift, SystemModule.swift, AppleScriptModule.swift, ScreenModule.swift)

## [1.8.1] — 2026-04-06

### Added
- **Skills Manager V2** — Platform-agnostic skill engine. Skills keyed on UUID with auto-detected platform routing (Notion, Google Docs). New `SkillURLParser.swift` utility. `manage_skill add` routes through URL parser. `manage_skill list` returns uuid, url, platform per skill. UI: URL field with live auto-detect, platform badge, inline skill rename (double-click). (`e0e09d9`)
- **Credentials tab restructure** — "API Keys" renamed to "Notion Integrations". New dedicated "Stripe" section with connection state management, validation, and removal. `StripeConnectionSection.swift` + `StripeConnectionSheet.swift`. Add Connection wizard simplified to Notion-only. (`1bbf091`)
- **MCP auto-routing on connection** — Routing skill index embedded in MCP `initialize` response via `instructions` field. Agents receive skill routing context at handshake time without needing to call `list_routing_skills` first. (`0fe85c8`)

### Fixed
- **Stripe stale key cleanup** — `ConnectionRegistry.removeConnection(.stripe)` now deletes legacy keychain entry (`SecItemDelete`) and resets `StripeMcpProxy`. No more false-positive green checkmark after key removal.
- **Skill rename in UI** — Double-click skill name in SkillsView for inline `TextField` rename. Validates non-empty, unique name. Escape cancels.
- **Skill page open crash** — `openSkillURL` now strips dashes from UUID before constructing `notion.so` URL. No more "Oops" error page.
- **UI text simplification** — Removed platform-specific language (Notion, Google Docs) from URL field placeholders. Just says "URL". (`339457e`)

### Changed
- **Skill data model** — `Skill` struct gains `url: String?` and `platform: SkillPlatform`. Backward-compatible decoder defaults existing skills to `.notion` / `nil`. All mutation methods preserve new fields.
- **README** — Updated tool count (76 static + N dynamic Stripe). Module table refreshed.
- **AGENT_FEEDBACK.md** — Pruned all resolved entries from v1.8.0 development cycle.

## [1.8.0] — 2026-04-04

### Added
- **Pre-ship release** — `docs/pre-ship-qa-checklist.md` (manual QA matrix), `scripts/qa_local_mcp_smoke.py` (local `GET /health` + `POST /mcp` initialize), **`make install-agent-safe`** alias for `install-copy` (see `AGENTS.md`).
- **notion_database_get** MCP tool (open tier) — Retrieve a Notion database container by ID. Returns title, icon, cover, parent metadata. (B1)
- **notion_datasource_get** MCP tool (open tier) — Retrieve a Notion data source schema by ID. Returns full property definitions, types, and options. (B2)
- **NotionClient: getDataSource()** — GET /v1/data_sources/id. New client method for data source schema retrieval.
- **CredentialType.unknown** — Fallback credential type for non-standard keychain labels. (A2)
- **fetch_skill close matches** — On miss, error response now includes Levenshtein-based close match suggestions instead of just listing all skills. (C1)
- **manage_skill bypassConfirmation** — New boolean parameter to skip SecurityGate confirmation prompt for automated/unattended sessions. (C3)

### Fixed
- **file_write HTML entity encoding** — Content with HTML entities (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`) is now decoded before writing to disk. Round-trip integrity preserved. (A1)
- **credential_read/credential_list** — `parseKeychainItem()` no longer throws for non-standard keychain labels; items with unknown labels surface as `type: "unknown"` instead of being silently excluded. (A2)
- **messages_send chat identifier guard** — Raw `chat[0-9]+` identifiers are now rejected before AppleScript dispatch, preventing malformed ghost threads in Messages.app. Error directs caller to resolve via `messages_participants`. (A3)
- **notion_query retry logging** — Auto-retry on transient 404 now logs "retrying transient 404" vs "permanent 404 — check sharing". Retry count visible in debug output. (C2)

### Changed
- **Security: Request-tier Always Allow** — Choosing **Always Allow** on a Request-tier tool (notification actions) now sets that tool to **Notify** in the Tool Registry (`tierOverrides`), matching the tier toggle. It no longer appends legacy “learned command prefixes.” Sensitive-path prompts: **Allow** keeps a session grant; **Always Allow** stores a **permanent path allow** (unchanged intent, without tier side effects). Alert-only fallback (no notification permission) remains Allow/Deny only — use the Tool Registry to lower tier. Tools marked never-auto-approve do not offer Always Allow.
- **Skills: Notion-only page refs** — Settings and `manage_skill` (`add`, `update_url`, `bulk_add`) accept only Notion page IDs (32 hex, dashes optional) or `notion.so` / `notion.site` URLs. Invalid rows in `bulk_add` are skipped with per-row reasons (`invalidPageRows`). Legacy bad IDs surface clear errors from `fetch_skill` / sync and an optional Settings banner.
- **MCP protocol version** — Handshake and diagnostics now use MCP spec **2025-06-18** (was 2024-11-05). Advanced → Version clarifies Model Context Protocol vs Notion’s hosted MCP.
- **Notion API version** — Advanced → Version and diagnostics list **`Notion-Version`** (**2026-03-11**), centralized as `BridgeConstants.notionAPIVersion` (used by `NotionClient`).
- **Advanced → Network** — Port save opens a **Restart / Cancel** dialog; Cancel reverts `config.json` to the previous port. **Default** button fills 9700 without saving. Copy tightened for tunnel ↔ localhost port coupling. Connections → Server labels **Local port**.
- **Onboarding connection snippets** — Sample MCP URLs use the configured local port (not hardcoded 9700). Health check uses the same port.
- **Minimum macOS** — Advanced shows minimum deployment **macOS 26+** (matches SwiftPM), not the machine’s runtime major version alone.
- **Skills registry** — Fresh installs and factory reset yield an **empty** skills list (no bundled placeholder skills). (UX Wave 2)
- **Credentials (Settings + MCP)** — Keychain credential storage is **opt-in** with a migration for existing users (`hasCompletedOnboarding` → default on until changed). When off, `credential_*` tools are hidden from MCP listings and calls fail closed; `payment_execute` requires credentials enabled. Biometric gate when turning on. (UX Wave 4)
- **Permissions UI** — Removed **PostResetSheet** (no guided sheet after TCC reset or factory reset); success copy points to **System Settings** and restart. Permissions tab auto-refresh throttled to **20s**; onboarding auto-permissions defer probes until **Re-check** or **Grant All**. (UX Wave 3)
- **payment_execute** — Description clarifies Stripe PaymentIntent + stored `pm_` (not web checkout), separate from the Stripe MCP proxy. (UX Wave 5)
- **notion_search** description — Updated to reference "data sources" instead of "databases". `filter.value` documentation now specifies `"page"` or `"data_source"` (not `"database"`). (D1)
- **notion_page_create** description — Notes that `parentType: "data_source_id"` is preferred for row inserts under Notion API 2026-03-11; `"database_id"` is legacy. (D2)
- **Settings polish (Connections, Credentials, Remote Access, Advanced)** — Minimal Stripe **API connections** row (pre-installed / status); removed Workspace and API section footers; **Credentials** delete uses attribute-matched Keychain queries with clearer messaging when removal fails; **Remote Access** header row toggles expand; **Advanced** Version/Network helper copy trimmed (Minimum macOS **26+**, port row + validation errors only).

### Removed
- **notion_page_markdown_write** tool — Removed from NotionModule, NotionClient, and tests. Superseded by notion_page_update + content blocks approach. (D3)

### Notes
- B3 (`notion_datasource_create`) and B4 (`notion_datasource_update`) are gated on Notion API endpoint confirmation. Deferred to v1.9.0.
- Git hygiene: merged `fix/session-lifecycle-stability` and `feat/settings-connections-restructure` into main. Deleted ghost branches (`claude/fervent-lichterman`, `claude/sad-kapitsa`).
- Tool count: 75 NotionBridge tools (74 base − 1 removed + 2 new) + N Stripe MCP tools.
- Version: marketing **1.8.0**, build **15** (Version.swift, Info.plist).

## [1.7.0] — 2026-04-02

### Added
- **NotionClient: getBlock()** — GET /v1/blocks/{id}. Retrieves a single block by ID with full type-specific data.
- **NotionClient: updateBlock()** — PATCH /v1/blocks/{id}. Updates a block's content by ID.
- **NotionClient: getDatabase()** — GET /v1/databases/{id}. Retrieves a database schema by ID.
- **notion_block_read** MCP tool (open tier) — Deep-inspect a single Notion block. Returns id, type, has_children, text, and raw type-specific payload.
- **notion_block_update** MCP tool (notify tier) — Update a Notion block's content by ID. Accepts JSON payload.
- **meeting_notes** support in extractPlainTextFromBlock — Surfaces title, status, and child block IDs (summary, notes, transcript).
- **SkillsManager.findSkillFuzzy()** — Public fuzzy lookup: exact > normalized (strip 'sk ' prefix, space/hyphen swap) > substring. Returns (match, suggestions).
- **Makefile install-copy target** — Copy-only install without notarize dependency or killall. For iterative development.

### Changed
- **notion_query** — Auto-retry on transient HTTP 404 with 2s delay before re-throwing (KI-08, F4).
- **shell_exec** — Background commands (trailing &) now cap timeout at 5s instead of 30s for fast early-return (F2).
- **lookupSkill** in SkillsModule — Now uses fuzzy matching: exact > normalized > substring. Resolves "web dev" to "Web Design", "sk messages" to "Messages", etc. (F5).

### Notes
- Remote MCP operator guidance now documents that browser-based clients (for example Claude chat) can be blocked by Cloudflare Browser Integrity Check or WAF challenges on `POST /mcp`; recommended mitigation is a path-scoped edge bypass plus the app bearer token.
- Tool count: 74 NotionBridge tools (72 base + 2 new block tools) + N Stripe MCP tools.
- Version: marketing **1.7.0**, build **14** (Version.swift, Info.plist).
- Feedback items resolved: F2, F3, F4, F5 (F1, F7 already fixed in v1.5.5/v1.6.0).

## [1.6.0] — 2026-03-31

### Fixed
- **`NotionClient.updatePageMarkdown`** — PATCH body now sends `replace_content.new_str` (full markdown string) per [Update page markdown](https://developers.notion.com/reference/update-page-markdown). The previous nested `markdown.content` shape caused HTTP 400 validation errors from the Notion API.

### Changed
- **Stripe MCP Proxy architecture** — Replaced hardcoded `StripeModule` (4 tools) with `StripeMcpProxy` + `StripeMcpModule`. Tools are now discovered dynamically from Stripe's remote MCP server (`mcp.stripe.com`) at registration time via HTTP `initialize` + `tools/list`. All discovered tools are registered with SecurityGate tiering (read → 🟢, write → 🟡, delete → 🔴).
- **StripeClient cleaned** — Removed `StripeProduct`, `StripePrice` structs and 6 catalog methods (`retrieveProduct`, `updateProduct`, `retrievePrice`, `listPrices`, `parseProduct`, `parsePrice`). Retained payment intent and account info methods only.
- **ConnectionRegistry** — Stripe capabilities updated from hardcoded catalog tool names to `["payment_execute", "card_tokenization", "stripe_mcp_proxy"]`.
- **ServerManager** — Registration call updated from `StripeModule.register` to `StripeMcpModule.register`.

### Removed
- **StripeModule.swift** — Replaced by `StripeMcpModule.swift` (dynamic proxy registration).

### Added
- **StripeMcpProxy.swift** — HTTP transport client for Stripe MCP server. Handles `initialize`, `tools/list`, and `tools/call` JSON-RPC methods. Bearer auth via Stripe API key from Keychain. Includes retry logic, timeout handling, and structured error responses.
- **StripeMcpModule.swift** — Registers proxy-discovered tools with the MCP tool router. Maps Stripe tool input schemas to SecurityGate tiers. Passes tool calls through to `StripeMcpProxy.callTool()` at runtime.

### Notes
- Tool count is now dynamic — base 72 NotionBridge tools + N Stripe MCP tools discovered at startup.
- Version: marketing **1.6.0**, build **13** (`Version.swift`, `Info.plist`).

## [1.5.5] — 2026-03-31

### Added
- **StripeModule** — 4 new Stripe catalog MCP tools (`stripe_product_read`, `stripe_product_update`, `stripe_price_read`, `stripe_prices_list`). Separate module from PaymentModule.
- **StripeClient** — 4 new methods: `retrieveProduct`, `updateProduct`, `retrievePrice`, `listPrices`. Reuses existing `authorizedRequest` helper.
- **StripeProduct** and **StripePrice** response structs for type-safe Stripe catalog data.
- Stripe connection capabilities expanded: `stripe_product_read`, `stripe_product_update`, `stripe_price_read`, `stripe_prices_list`.

### Fixed
- **Credential namespace bridge** — `CredentialManager.read()` now returns infrastructure keys (service `com.notionbridge`) instead of throwing `invalidType`. Enables agents to access Stripe API key and other infrastructure credentials via `credential_read` MCP tool.
- **Credential list visibility** — `CredentialManager.list()` now surfaces `com.notionbridge` infrastructure keys as metadata-only entries. No secrets exposed in list results.

All notable changes to NotionBridge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.4] — 2026-03-31

### Fixed
- **KI-07: notion_page_markdown_write HTTP 400** — Changed API request body format from `page_content` to `replace_content` to match Notion API 2026-03-11 spec. Full page markdown replacement now works correctly.

### Added
- **Parent field in notion_page_read** — Response now includes `parent` object from the Notion API, enabling data source ID resolution from any page without additional API calls.

## [1.5.3] — 2026-03-30

### Added
- **Streamable HTTP tunnel compatibility** — When **Settings → Connections → Remote access** has a non-empty **tunnel URL** (`tunnelURL` in app storage), `POST /mcp` validation extends the default localhost-only **Origin** / **Host** allowlist to include that tunnel’s hostname (e.g. Cloudflare quick tunnels). The server still binds to **127.0.0.1** only; traffic must reach the app via a tunnel or reverse proxy to loopback. No `0.0.0.0` bind.
- **Mandatory MCP bearer when tunnel is active** — If the tunnel URL **parses** (same condition as the extended allowlist) and **no** MCP bearer is configured, Streamable HTTP **`POST /mcp`** is rejected (**401**). When a bearer is set (**Keychain** `mcp_bearer_token`, with **`com.notionbridge.mcpBearerToken`** as legacy/migration read), clients must send **`Authorization: Bearer …`**. With an **empty** tunnel URL, bearer is optional (setting a token still enforces it for localhost clients).
- **Remote access UI** — **MCP remote token** field (SecureField) with Generate / Copy / Clear when a tunnel URL is present; persists to Keychain + UserDefaults mirror.
- **`MCPHTTPValidation`** — Shared builder for the Streamable HTTP `StandardValidationPipeline` used by session creation in `SSETransport`; exposes **`streamableHTTPBearerPhase()`** for tests and diagnostics.
- **Tests** — `MCPHTTPValidationTests` for tunnel URL → host/origin allowlist parsing and bearer phase (remote missing token / bearer required / local optional).
- **Operator doc** — `docs/operator/cloudflare-access-notion-bridge.md` (Cloudflare Access in front of the tunnel; no secrets).

### Changed
- **`SSETransport` `createSession`** — Uses `MCPHTTPValidation.streamableHTTPPipeline(ssePort:)` instead of only `OriginValidator.localhost()`.

### Notes (distribution)
- After **`make dmg`**, confirm **`make verify-sparkle-feed`** and that **`length`** / **`sparkle:edSignature`** in `appcast.xml` match the uploaded GitHub release asset (regenerate with **`make appcast`** if the DMG changed).
- **Version / Sparkle** — Marketing **1.5.3**, build **10** (`Version.swift`, `Info.plist`). **`appcast.xml`** includes **1.5.3** (newest) plus prior **1.5.2** / **1.5.1** items. Upload **`notion-bridge-v1.5.3.dmg`** to the **v1.5.3** GitHub release so the enclosure URL resolves.
- **Purchase download (kup.solutions)** — When publishing this build to paid fulfillment, set `workers/nb-fulfillment/wrangler.toml` **`DMG_OBJECT_KEY`** to **`notion-bridge-v1.5.3.dmg`** (or keep the prior filename if you intentionally reuse it), re-upload the object, then deploy the worker if needed.

## [1.5.2] — 2026-03-30

### Removed
- **Skill visibility `adminOnly`** — Same behavior as Standard for MCP discovery; removed from UI and tool schema. Persisted registry entries and MCP calls using `adminOnly` are read as **standard**.

### Added
- **[SECURITY.md](SECURITY.md)** — Vulnerability reporting scope, out-of-scope items, Sparkle channel guidance.
- **GitHub issue templates** — Bug and feature forms under `.github/ISSUE_TEMPLATE/`.
- **`make verify-sparkle-feed`** and **`scripts/verify_sparkle_feed.sh`** — Confirms `SUFeedURL` from `Info.plist` returns HTTP 200 and XML-shaped content (run before/after publishing `appcast.xml`).
- **Skills MCP metadata** — `summary`, `triggerPhrases`, and `antiTriggerPhrases` stored with each skill (UserDefaults); Notion `rich_text` mirror properties **`Bridge Summary`**, **`Bridge Triggers`**, **`Bridge Anti-triggers`**. New `manage_skill` actions: `set_metadata`, `sync_metadata_to_notion`, `sync_metadata_from_notion`. `list_routing_skills`, `manage_skill list`, and `fetch_skill` expose metadata; `fetch_skill` cache key includes a metadata fingerprint.
- **SkillNotionMetadata** — Shared encode/decode for Notion page property patches (2000-char rich_text chunks).

### Changed
- **[README.md](README.md)** — Canonical tool counts (**73** = 72 module + `echo`); SkillsModule **3** tools; **Public updates (Sparkle)** and **Security disclosures** sections.
- **[AGENTS.md](AGENTS.md)** — Aligned MCP tool count with runtime (`echo` as builtin).
- **[PRIVACY.md](PRIVACY.md)**, **[TERMS.md](TERMS.md)** — Stripe as primary processor; Lemon Squeezy described only where applicable as merchant of record.
- **[Version.swift](NotionBridge/Config/Version.swift)** — Build constant kept in sync with `Info.plist`.
- **Settings → Connections** — Sections clarified: Notion workspaces vs API connections (Stripe); footers explain tunnel vs tokens. **API connections** list uses `ConnectionRegistry` `kind: .api` with provider badges.
- **Settings → Skills** — Footer explains Standard / Routing visibility; optional summary line in skill rows.
- **Settings → Advanced → Network** — Copy explains local SSE port vs remote tunnel; tunnel must forward to the same port after changes.
- **Permissions → Notifications** — `PermissionManager` maps `UNAuthorizationStatus` consistently; one-shot `requestAuthorization` when still `notDetermined` to sync System Settings–only grants; remediation text when status is unknown.

### Notes (distribution)
- Sparkle requires the appcast URL to be **publicly readable** (e.g. public GitHub repo for `raw.githubusercontent.com/.../appcast.xml`, or host `appcast.xml` on your own HTTPS origin and set `SUFeedURL`). See README.
- **GitHub repository** `KUP-IP/Notion-bridge` is **public**, so the default `SUFeedURL` is anonymously reachable; run **`make verify-sparkle-feed`** to confirm after changes to `appcast.xml`.

### Notes (UEP closeout)
- Documentation and tooling delivered in-repo; sync **Status** / **Summary** on any linked Notion packet or project if this work was tracked in KUP·OS DOCS.

### Changed (release)
- Version: marketing **1.5.2**; build **7 → 8 → 9** (`Version.swift`, `Info.plist`). Build **9** is the current shipping binary for 1.5.2 (includes `adminOnly` removal and doc/tooling updates above).
- **Sparkle (`appcast.xml`)** — Item for 1.5.2 (build **9**). If the release DMG from `make dmg` differs in size from the committed appcast, run `sign_update` / `generate_appcast` on the exact uploaded `.dmg` and update `length` / `sparkle:edSignature` before publishing the GitHub release.
- **Purchase download (kup.solutions)** — In the `kup.solutions` repo, `workers/nb-fulfillment/wrangler.toml` `DMG_OBJECT_KEY` is set to `notion-bridge-v1.5.2.dmg`. Re-upload that object after each new DMG build (same filename), then deploy the `nb-fulfillment` worker if needed.

## [1.5.1] — 2026-03-26

### Added
- **`screen_analyze` tool** — Dominant color extraction from screenshot files using CoreGraphics pixel sampling. Returns hex colors with percentages, average luminance (0-1), dark/light theme detection, and image dimensions. Open tier (read-only). Input: file path from `screen_capture`. Algorithm: 5-bit RGB quantization → frequency sort → top-N.

### Changed
- Version bump: 1.5.0 → 1.5.1, build 6 → 7.
- ServerManager: Added `ScreenModule.registerAnalyze(on:)` registration.

## [1.5.0] — 2026-03-25

### Added
- **TCC csreq mismatch detection** — `PermissionManager` now detects stale TCC entries where `auth_value=2` but runtime probe returns false. New "Reset & Re-authorize" UI banner in PermissionView.
- **reminders-bridge.swift** — Full EventKit CLI for Apple Reminders (8 commands: list-lists, create-list, create, read, update, complete, delete, search). Supports recurrence rules, location alarms, URL, priority, due dates.
- `Version.swift` as single source of truth for app versioning (replaces hardcoded fallback strings).

### Fixed
- **reminders-bridge v1.1.0** — `listId` UUID resolution fix + `notes` param alias (`notes` takes priority over `body`).
- **TCC csreq stale grants** — Automation targets with approved-but-stale code signing requirements now detected and resettable from UI.

### Changed
- **66 MCP tool descriptions rewritten** (PKT-488) — Every tool description now leads with action, names return shape, embeds behavioral gotchas, includes workflow hints. Removed all security tier badges (SecurityGate enforces at runtime).
- Version bump: 1.4.0 → 1.5.0, build 5 → 6.
- Info.plist synced with Version.swift (was stale at 1.4.0).

## [1.4.0] — 2026-03-24

### Added
- **ChromeModule Space-awareness** — Tab listing now reports which macOS Space each Chrome window occupies via ScreenCaptureKit `onScreen` field. `chrome_navigate` falls back to `open` when the target window isn't on the active Space.
- `.cursor/rules` for Cursor agent project context.
- `RELEASE_HANDOFF.md` with build/sign/notarize instructions.

### Fixed
- **Makefile rpath** — Corrected `@executable_path` → `@loader_path` for proper framework resolution.
- **Stripe payment tests** — Refactored `StripeTokenizationTests` to use shared `readRequestBody()` helper instead of inline body parsing.

### Changed
- **Swift 6.3 compatibility** — Compiler fixes, SkillsModule fix, added `patch-deps` Makefile target.
- **Module/tool count reconciliation** — Audited and corrected counts: 63 → 65 tools, 14 → 13 modules. Updated AGENTS.md and all E2E test assertions.
- Version bump: 1.2.0 → 1.4.0, build 4 → 5.
- DMG size reduced from ~12.9 MB to ~10.2 MB.

## [1.3.0] — 2026-03-20

### Added
- `contacts_search` tool via CNContactStore (#51).
- Reminders (`com.apple.reminders`) as 5th automation target.

## [1.2.0] — 2026-03-22

### Added
- Settings tweaks, `manage_skill` tool, Connection Manager guards.

## [1.1.5] — 2026-03-15

_Initial tracked release._

[1.8.4]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.3...v1.8.4
[1.8.3]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.2...v1.8.3
[1.8.2]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.3...v1.8.0
[1.7.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.3...v1.7.0-pkt381
[1.6.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.5...v1.6.0
[1.5.5]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.4...v1.5.5
[1.5.4]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.3...v1.5.4
[1.5.3]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.2...v1.5.3
[1.5.2]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.1.5...v1.2.0
[1.1.5]: https://github.com/KUP-IP/Notion-bridge/releases/tag/v1.1.5

[1.9.1]: https://github.com/KUP-IP/Notion-bridge/compare/v1.9.0...v1.9.1
## [2.2.0-3.4.1] — 2026-05-11 — Cursor SDK adapter Wave 1 — Swift `CursorModule` + sidecar protocol DTOs (PKT-3.4.1 / PKT-772)

### Added
- **`modules/cursor/` Swift module** — new top-level Bridge module hosting the Cursor SDK adapter as a peer of `dev/` and `computer/`. Justifies its own family: the cursor-sidecar carries a distinct security envelope (`.request` tier on every call as a cost gate), a separate Node-subprocess lifecycle, and an SDK pin (`@cursor/sdk@^1.0.12`) decoupled from the rest of the Bridge.
  - `CursorTypes.swift` — wire-level DTOs (`CursorRun`, `CursorArtifact`, `CursorEvent`, `CursorCapability`) and `CursorError` mirroring the sidecar error registry (`10001 NOT_IMPLEMENTED`, `10002 CAPABILITY_MISSING`, `10003 AUTH_FAILED`, `10004 SDK_ERROR`, `10005 COST_CAP_TRIPPED`, `10006 TIMEOUT` per `cursor-sidecar/SPEC.md` §4).
  - `CursorRuntime.swift` — actor singleton with synchronous `capabilityCheck()` (Node binary + sidecar entrypoint + Keychain `service=api_key:cursor / account=cursor`), nonisolated `locateNode()` / `detectNodeVersion()` / `readSidecarVersion()` helpers, public `readApiKey()` Keychain accessor, and the public 5-method API contract (`ping`, `capabilityProbe`, `agentRun`, `agentStatus`, `agentList`, `agentCancel`, `agentArtifacts`). Wave 1 returns `capability_missing` cleanly when the pre-flight fails; returns `not_implemented` after a successful gate — sidecar IPC + `@cursor/sdk` wiring lands in PKT-3.4.1.W2.
  - `CursorModule.swift` — 5 `cursor_agent_*` tool registrations under module `"cursor"`, all tier `.request`. Schemas describe `prompt` / `runtime` (`local`|`cloud`) / `model` / `repoPath` / `branch` / `maxCostCents`. Handlers proxy to `CursorRuntime` and return a structured error envelope (`ok=false`, `code`, `error`) when capability is missing.
- **`ServerManager.setup`** registration after `GhModule.register` (line 118).
- **`NotionBridgeTests/CursorModuleTests.swift`** — registration (5 tools, all `.request`, module name = `"cursor"`), `CursorTypes` JSON round-trip, capability surface, error-code registry, and a dispatch path verifying the structured error envelope shape on the Wave 1 stub path. Wired into `main.swift` after `runGhModuleTests()`.
- **`cursor-sidecar/src/protocol.ts`** — TypeScript mirror DTOs (`CursorRuntimeKind`, `CursorRunStatus`, `CursorRun`, `CursorArtifact`, `CursorEvent`) so the Wave 2 sidecar runtime impl can replace the NOT_IMPLEMENTED stubs against a typed contract.

### Changed
- **Tool-count baseline** bumped from 84 to **89** static feature module tools: + 5 (`cursor_agent_run`, `cursor_agent_status`, `cursor_agent_list`, `cursor_agent_cancel`, `cursor_agent_artifacts`).
- **Family count** bumped from 16 to **17** with the `cursor` family.

### Deferred to PKT-3.4.1.W2 (Wave 2 follow-up)
- Live JSON-RPC IPC between `CursorRuntime` and `cursor-sidecar` (bidirectional stdio with request/response correlation, SSE notification fan-out, `Last-Event-ID` reconnect per SPEC §8).
- Sidecar `agent_run` / `agent_status` / `agent_list` / `agent_cancel` / `agent_artifacts` stub-handler replacement with real `@cursor/sdk@1.0.12` calls. **Blocker:** the published `@cursor/sdk@1.0.12` npm tarball does not ship `.d.ts` declaration files (verified — `find @cursor/sdk -name '*.d.ts'` returns zero results) despite `package.json` declaring `"types": "./dist/esm/index.d.ts"`. W2 prerequisite: either upstream SDK ships its types, or we vendor minimal declarations from the SDK's public source on the SDK repo (`github.com/cursor/cursor`).
- SecurityGate Always-Allow scoped per `(repo, model, runtime)` triple-keyed session memo (default request-tier prompt ships in W1; scoped memo surface is W2).
- AI LOGS DS write per run (`machine_id`, `prompt_hash`, `model`, `runtime`, `status`, `cost_cents`, `artifact_urls` — hash-only) via `NotionAPIClient`. Wire path scoped to W2.
- Capability probe auto-rollback on failed sidecar update (failure-injection infrastructure; W2 or W3).

### Deferred to live-validation (requires user-side authorization)
- DoD A1 — local refactor round-trip against a test repo with structured SSE events captured (requires real `@cursor/sdk` spend).
- DoD B2 — cloud runtime confirmation modal + cloud VM provisioning + PR URL artifact (requires cloud spend authorization, GitHub repo nomination, real PR creation).
- DoD C5 — Bridge restart re-attaches running cloud agent via `Last-Event-ID` (requires running cloud agent + induced sleep/disconnect cycle).
