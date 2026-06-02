// CloudAccessFirstRun.swift — WS-G (Bridge Cloud Access · first-run + Claude.ai)
// NotionBridge · Modules · Cloud
//
// Pure, Sendable decision helpers for the WS-G (PKT-923) terminal packet:
//
//   1. FirstRunCloudAccessGate — the one-time presentation gate for the
//      FirstRunCloudAccessModal. Factored out of the SwiftUI view so the
//      "shown exactly once" rule is unit-asserted headlessly (no sheet, no
//      WindowServer) — the same headless-decision shape ProvisioningPresentation
//      uses.
//
//   2. ClaudeAIIntegration — builds the claude.ai integrations deep link and
//      the copy+hint fallback string. Q3 (COA 2026-05-27) locked the URL shape
//      to `https://claude.ai/settings/integrations?mcp_url={encoded}` IF the
//      format could be confirmed to navigate correctly; otherwise fall back to
//      copy + an inline instruction. Verification at build time (2026-06-02)
//      could NOT confirm the format — claude.ai rejects unauthenticated
//      navigation (HTTP 403, Cloudflare bot wall) and there is no public doc
//      confirming the `mcp_url` query param is honored on the integrations
//      page. Per the Q3 lock we therefore ship the COPY + HINT fallback. The
//      encoded-URL builder is retained (and unit-tested) so a future confirmed
//      format flips a single `mode` flag rather than re-deriving the encoding.

import Foundation

// MARK: - First-run gate

/// Decides whether the first-run cloud-access guide should be presented.
///
/// The rule (Q2 lock, COA 2026-05-27): the modal is shown exactly once, the
/// first time cloud access reaches the online/connected state, and never
/// again once the user has dismissed it (persisted via
/// `BridgeDefaults.hasSeenCloudAccessFirstRun`).
public enum FirstRunCloudAccessGate {

    /// Whether to present the first-run modal.
    ///
    /// - Parameters:
    ///   - isOnline: true when cloud access has reached the connected/online
    ///     state (RemoteAccessSection.DisplayState.online).
    ///   - hasSeenFirstRun: the persisted `hasSeenCloudAccessFirstRun` flag.
    /// - Returns: true only when online AND the flag is not yet set.
    public static func shouldPresent(isOnline: Bool, hasSeenFirstRun: Bool) -> Bool {
        isOnline && !hasSeenFirstRun
    }
}

// MARK: - Add to Claude.ai

/// Builds the artifacts the "Add to Claude.ai" button uses: the MCP URL the
/// user pastes, the (retained-but-gated) claude.ai deep link, and the
/// copy+hint fallback shipped per the Q3 verification outcome.
public enum ClaudeAIIntegration {

    /// How the "Add to Claude.ai" affordance behaves.
    public enum Mode: Sendable, Equatable {
        /// Open `claude.ai/settings/integrations?mcp_url=…` in the browser.
        /// Reserved for when the deep-link format is confirmed (Q3).
        case openBrowser
        /// Copy the MCP URL to the clipboard and show an inline paste hint.
        /// The shipped default (Q3 unconfirmed → fallback).
        case copyAndHint
    }

    /// The shipped mode for this build. Q3 verification (2026-06-02) could not
    /// confirm the deep-link format, so we ship `.copyAndHint`.
    public static let shippedMode: Mode = .copyAndHint

    /// The claude.ai integrations base (no query).
    public static let integrationsBase = "https://claude.ai/settings/integrations"

    /// The inline hint shown beneath the button in `.copyAndHint` mode.
    public static let pasteHint = "Copied. Paste in Claude.ai → Settings → Integrations."

    /// The MCP URL the user connects with, derived from the cloudflared tunnel
    /// hostname. `nil` when no hostname is provisioned yet (button disabled).
    public static func mcpURL(forHostname hostname: String?) -> String? {
        guard let host = hostname, !host.isEmpty else { return nil }
        return "https://\(host)/mcp"
    }

    /// The claude.ai deep link with the MCP URL percent-encoded into the
    /// `mcp_url` query parameter. Retained + unit-tested so a future confirmed
    /// Q3 format is a one-line `shippedMode` flip. `nil` when no MCP URL exists
    /// or encoding fails.
    ///
    /// Encoding uses `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`
    /// per the packet, then additionally escapes the sub-delimiters that
    /// `.urlQueryAllowed` leaves intact but that would corrupt a value embedded
    /// in a query (`&`, `+`, `=`, `?`, `/`, `:`), so the round-tripped value is
    /// exactly the original MCP URL.
    public static func deepLink(forHostname hostname: String?) -> URL? {
        guard let mcp = mcpURL(forHostname: hostname) else { return nil }
        guard let encoded = encodeQueryValue(mcp) else { return nil }
        return URL(string: "\(integrationsBase)?mcp_url=\(encoded)")
    }

    /// Percent-encode a value for safe embedding as a query-parameter value.
    /// Exposed for direct unit assertion of the URL-encoding contract.
    public static func encodeQueryValue(_ value: String) -> String? {
        // Start from .urlQueryAllowed (per packet), then remove the
        // sub-delimiters that are legal in a query *component* but ambiguous
        // inside a single parameter *value*.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/:;@$,")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
