# Project: The Bridge (TheBridge)

## Overview
A macOS menu-bar app that exposes the Mac + a Notion workspace to AI agents over MCP
(stdio + Streamable-HTTP `/mcp` + legacy SSE `/sse`). Ships as "The Bridge.app"
(bundle id `kup.solutions.notion-bridge`), updated via Sparkle. SwiftPM, no Xcode project.

## Architecture
- **Library target `TheBridgeLib`** holds everything testable; thin `TheBridge`
  executable wraps it. Tests are a custom harness (`TheBridgeTests`), NOT XCTest.
- **MCP server:** `Server/SSEServer` (`SSETransport.swift`) serves `/mcp`, `/sse`,
  `/health`, job callbacks. Tools register via `Server/BridgeModuleRegistry.swift`
  (single source of truth, ~172 tools / 27 families) → `ToolRouter` → `MCPToolFactory`.
- **Tools:** `ToolRegistration {name, module, tier, inputSchema (MCP Value), handler}`.
  Every live tool MUST have a `ToolAnnotationCatalog` entry — `ToolAnnotationAuditTests`
  hard-fails the build otherwise. Tiers: `.open`/`.notify`/`.request` (`SecurityGate`).
- **Notion:** `Notion/NotionClient` (actor, per-connection, 3 req/s token bucket),
  `NotionClientRegistry` (multi-workspace, `getClient(workspace:)`). `getDataSource()`
  returns property **ids** + types. No central rate limiter yet (registry W2 adds one).
- **Durable work:** `JobStore` (SQLite/WAL, `job_backlog` idempotent queue, single-flight
  drain on launch/wake/cloud-online) — the reuse template for any offline outbox.
- **Paths/config:** `Core/BridgePaths` (`~/Library/Application Support/The Bridge/…`,
  `overrideHomeForTesting` for hermetic tests), `Config/ConfigManager`
  (`~/.config/notion-bridge/config.json`), `Core/BridgeDefaults` (UserDefaults keys).
- **UI:** SwiftUI Settings under `UI/Sections/*`, `SettingsSection` enum in
  `UI/SettingsWindow.swift`, design tokens in `UI/BridgeTokens.swift`.

## Dev Commands
- Build (release, strict concurrency): `make build`
- Test: `make test` (debug build + run harness) — or `.build/debug/TheBridgeTests`
- Test floor gate: `make test-floor` (`scripts/test-floor-gate.sh`) — green-count must be ≥ FLOOR
- Install signed (keeps TCC identity, does NOT relaunch): `make install-copy` then
  `open -a "The Bridge"`. NOTE: the GUI app gets env (`BRIDGE_ENABLE_HTTP`, WorkOS, …)
  from the `solutions.kup.bridge-env` LaunchAgent; an `open` from a non-GUI shell may
  not inherit it (then `connectorAuth` is nil — local loopback still works).
- Release = merge to `main` + push a `v*` tag; `release.yml` builds/notarizes/publishes
  the DMG + appcast. Do NOT hand-build the DMG/appcast (breaks Sparkle signature).

## Key Constraints
- **Test floor (`scripts/test-floor-gate.sh`):** adding tests → measure new green count,
  raise `FLOOR=` to it, add a dated provenance comment. Never lower without a recorded reason.
- **Tool annotations:** new tools need a `ToolAnnotationCatalog` entry (audit invariant).
- **Notion writes:** create-then-update (don't set properties via create-on-data-source);
  surgical body edits via `replacePageMarkdown` (read-modify-write, exact `old_str` match).
- **Loopback contract (PKT-810 R5):** `/mcp` from direct loopback (no `Cf-*` header) is
  token-free; only tunnel (Cloudflare `Cf-Connecting-Ip`/`Cf-Ray`) requests are auth-gated.
  The legacy `/sse` + `/messages` routes are dispatched *before* that gate, so they enforce
  their own check: tunnel-origin legacy requests are **403'd (loopback-only)**; only `/health`
  + the PRM doc are intentionally tunnel-reachable without auth. cloudflared forwards ALL paths
  to `:9700` (no path scoping), so the server is the trust boundary.
- **Version:** `Config/Version.swift` (marketing 3.8.1, build 60) + root `Info.plist`
  (CFBundleShortVersionString/CFBundleVersion — the build reads the plist, keep both in sync).
  +1 patch per published install.

## Current Sprint
**Data-Source Registry — vertical slice SHIPPED + live-verified** (spec: config-driven
`entity type → Notion data source + property map bound by PROPERTY ID`; foundation for
"Sell The Bridge"). All under `Modules/Registry/` (13 files) + `UI/Sections/DataSourcesSection.swift`.
Floor 2030→**2163** (+133 tests). Live-verified against real Notion (Skills 8/8 bound;
Projects added+introspected with correct drift; possess loaded a 16KB skill body).
**Shipped in v3.8.1** (PR #40 merged to main; build 60) alongside the PKT-810 R5 legacy-route
tunnel-gate security fix (+5 tests).

- **W1 ✓** `RegistryModels` (bind-by-property-id, Skills seeded entity #1) · `RegistryConfigStore`
  (atomic exportable `registry.json`) · `RegistryRowCache` (per-entity read-through, stale-
  while-revalidate + offline; generalized from `SkillBodyCacheStore`).
- **W2 ✓** `RegistryPropertyCodec` (typed Value↔Notion JSON) · `RegistryRateLimiter` (central
  2 req/s) · `RegistrySchemaBinder` (bind-by-name→ids + type drift, Decision 9) · `RegistryGateway`
  (protocol + `LiveRegistryGateway`) · `RegistryReader` (read-through+offline+possess) · `RegistryWriter`
  (create-then-update / update / soft-delete, keyed by property id).
- **W3 ✓** `RegistryModule` — 9 tools (module `registry`): `registry_entities/add_entity/introspect/
  list/get/create/update/delete/possess`. One generic set serves every entity. staticFeature
  ModuleToolCount 162→171 (+ bridge_status = 172 live).
- **W4 ✓** `DataSourcesViewModel` (propose→confirm onboarding, Decision 5) + `DataSourcesSection`
  pane (`SettingsSection.datasources`). BE↔FE share the same config+gateway seam (alignment tested).
- **W5 ✓** `registry_add_entity` (register any data source at runtime) + live end-to-end verify.

**Deferred (per the spec's own phasing / separate scope):** v2 entities (Events·BLOCKS·AI Logs);
heavier domain verbs (`recall` embeddings via Ollama — Decision 9 separate project; `log-interaction`,
`brief`, `consolidate`, `close`, `schedule`); backwards-sync outbox (reuse `JobStore`); a
`registry_remove_entity` tool + a pane "add data source" affordance. Skills `fetch_skill`/`skill_*`
left intact (additive-first; convergence is a later wave). The shipped seed is Skills-only — v1 hot
Projects/Contacts/Memory are added via `registry_add_entity`/the pane (Decision 5: don't ship hardcoded
data-source IDs).

Design decisions: typed exportable `registry.json`; **generic** CRUD tools (not per-entity, keeps
surface small); bind writes/reads by PROPERTY ID (rename-safe), match-by-name only at introspect.
