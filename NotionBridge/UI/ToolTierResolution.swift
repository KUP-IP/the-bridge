// ToolTierResolution.swift — Pure tier-source resolution for the Tool Registry UI
// NotionBridge · UI
//
// fb-securitygate-revoke-ui: the Tool Registry now has to render BOTH a tool's
// module-aware effective tier AND *where that tier comes from* (the tool's own
// override vs a module-scoped "Always Allow" grant vs the registered default),
// and offer a per-module revoke. This pure helper is extracted so the view and
// its tests share one source of truth without a live view / UserDefaults, and so
// override precedence can never drift from `ToolRouter.resolveEffectiveTier`.

import Foundation

/// Which layer supplies a tool's effective security tier. Drives the Tool
/// Registry annotation ("tier via <module> grant") and the revoke affordance.
public enum ToolTierSource: Equatable, Sendable {
    /// A per-tool override (`BridgeDefaults.tierOverrides`) — most specific.
    case ownOverride
    /// A per-module "Always Allow" grant (`BridgeDefaults.moduleTierOverrides`).
    case moduleGrant
    /// No override — the tool's registered default tier.
    case registeredDefault
}

/// Pure resolution of a tool's effective tier + its source. Mirrors
/// `ToolRouter.resolveEffectiveTier` precedence exactly: per-tool override >
/// per-module override > registered default. `neverAutoApprove` is not modelled
/// here because `ToolInfo` (the UI struct) does not carry it; the router remains
/// the authority for execution-time gating.
public enum ToolTierResolution {

    /// Effective tier rawValue. Delegates to `ToolRouter.resolveEffectiveTier`
    /// so the UI display can never disagree with the router's actual decision.
    public static func effectiveTier(
        toolName: String,
        module: String,
        registeredTier: String,
        toolOverrides: [String: String],
        moduleOverrides: [String: String]
    ) -> String {
        let registered = SecurityTier(rawValue: registeredTier) ?? .open
        return ToolRouter.resolveEffectiveTier(
            toolName: toolName,
            module: module,
            registeredTier: registered,
            neverAutoApprove: false,
            toolOverrides: toolOverrides,
            moduleOverrides: moduleOverrides
        ).rawValue
    }

    /// Which layer determined the effective tier. A per-tool override wins over a
    /// module grant; a module grant wins over the registered default. Only counts
    /// an override entry whose value parses to a real `SecurityTier`, matching the
    /// router (a malformed entry falls through to the next layer).
    public static func source(
        toolName: String,
        module: String,
        toolOverrides: [String: String],
        moduleOverrides: [String: String]
    ) -> ToolTierSource {
        if let raw = toolOverrides[toolName], SecurityTier(rawValue: raw) != nil {
            return .ownOverride
        }
        if !module.isEmpty, let raw = moduleOverrides[module], SecurityTier(rawValue: raw) != nil {
            return .moduleGrant
        }
        return .registeredDefault
    }
}
