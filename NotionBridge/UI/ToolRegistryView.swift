// ToolRegistryView.swift — RETIRED (feat/v4-redesign)
// NotionBridge · UI
//
// The flat, per-module Tool Registry tab (`ToolRegistryView`) has been
// retired. The LIVE Tools surface is now `ModuleGroupList` in
// `ModuleGroupCard.swift` — the v4 database/table view (BridgeToolTable +
// BridgeToolGroupRow + BridgeToolRow + BridgeTierPill) that ports
// `design/.../pages/page-tools.jsx` with the super-section grouping, search,
// family filter, and live registry-bound counts.
//
// Why this file is now empty:
//   • `ToolRegistryView` had zero instantiations — `SettingsWindow+Sections`
//     renders `ModuleGroupList`, never this view (v4 QA: dead code).
//   • Keeping a parallel, un-wired table risked drifting from the live one
//     (off-design `shippingbox` glyph, joined-name descriptions, raw fonts).
//   • SPM compiles every file in this folder, so the source is reduced to
//     this note rather than deleted (file removal is a project-manifest op).
//
// Where its responsibilities went:
//   • Per-tool enable + Open·Notify·Confirm tier cycling → ModuleGroupList
//     (BridgeToolRow + cycleTier, persisting BridgeDefaults.tierOverrides).
//   • Module-scoped "Always Allow" grant + Revoke UI → Security ▸ Gates
//     (PermissionsSection, writing BridgeDefaults.moduleTierOverrides).
//   • Live enabled/total stat strip → ModuleGroupList.pageHead.
//
// Persistence keys + the `.notionBridgeTierOverridesDidChange` notification
// are unchanged; nothing that read this view's writes is affected.
