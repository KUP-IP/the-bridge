// MenuBarIconResolver.swift — crash-loop-proof menu-bar icon resolution
// fix(sparkle): graceful degradation for a corrupt / missing SPM resource bundle
//
// ROOT CAUSE (LIVE 2026-06-05). Sparkle's staged-update swap left the app's SPM
// resource bundle `TheBridge_TheBridge.bundle` WITHOUT a `Contents/` dir
// (a mixed-version / raced install). The previous `loadMenuBarIcon()` reached
// the icon via the SPM-generated `Bundle.module` accessor. That accessor is
// NOT a normal optional lookup — SwiftPM synthesizes it to `_assertionFailure`
// (trap) when the resource bundle cannot be found OR loaded. So a corrupt
// bundle made `Bundle.module` static-init TRAP during `loadMenuBarIcon()` at
// the menu-bar-icon load site → EXC_BREAKPOINT / SIGTRAP on EVERY launch — a
// bootable-but-crash-looping app that required a manual clear-staging +
// reinstall to recover.
//
// THE FIX (the crash-loop killer). Never touch the trapping `Bundle.module`
// accessor on the launch path. Resolve the icon through `MenuBarIconResolver`,
// which:
//   • walks a list of CANDIDATE bundle paths via `Bundle(path:)` — which
//     RETURNS nil (never traps) for a missing/corrupt bundle, and never trips
//     the synthesized `_assertionFailure`,
//   • additionally tries `Bundle.main` (the .app's own Resources) directly,
//   • and, if no candidate yields a usable image, returns a `.fallback`
//     outcome so the caller can substitute a system SF Symbol.
// The app therefore ALWAYS boots: worst case it shows the SF Symbol menu-bar
// glyph and logs, instead of trapping.
//
// This file lives in the TheBridgeLib target (alongside AppDelegate) so the
// PURE guard logic is unit-testable with an INJECTED bundle path — the
// executable-target `loadMenuBarIcon()` is a thin wrapper that feeds the real
// candidate paths in.

import AppKit
import Foundation

/// Outcome of resolving the menu-bar icon. `.resource` carries a real image
/// loaded from a resource bundle; `.fallback` means no resource image was
/// loadable and the caller MUST substitute a system SF Symbol. The enum makes
/// the degradation path explicit and testable (we can assert `.fallback`
/// without rendering AppKit).
public enum MenuBarIconResolution: Sendable, Equatable {
    case resource
    case fallback
}

/// Crash-loop-proof resolver for the menu-bar icon. All lookups are
/// non-trapping (`Bundle(path:)` / `Bundle.image(forResource:)` both return
/// optionals), so a missing or structurally-corrupt SPM resource bundle can
/// NEVER abort the process here — it degrades to `.fallback`.
public enum MenuBarIconResolver {
    /// The SF Symbol used when no resource image is loadable. A neutral,
    /// always-present system glyph so the menu-bar item is still clickable and
    /// the app remains fully usable while the bundle is broken.
    public static let fallbackSymbolName = "rectangle.connected.to.line.below"

    /// Asset name looked up inside each candidate bundle.
    public static let iconResourceName = "MenuBarIcon"

    /// Point size the menu-bar icon is rendered at (notched-MBP friendly).
    public static let iconPointSize: CGFloat = 30

    /// Pure, non-trapping decision: given an ordered list of candidate resource
    /// bundle paths and a probe that reports whether a given bundle path yields
    /// a usable icon image, decide whether a resource image is available or the
    /// caller must fall back to the SF Symbol.
    ///
    /// This is the seam the regression test drives. It NEVER touches
    /// `Bundle.module` (which would trap on a corrupt bundle) and NEVER force-
    /// unwraps. `imageProbe` returns `true` iff a real image was loaded from
    /// that bundle path; injecting a probe that always returns `false`
    /// simulates a missing/malformed bundle and MUST yield `.fallback` rather
    /// than trapping.
    ///
    /// - Parameters:
    ///   - candidateBundlePaths: ordered resource-bundle paths to try.
    ///   - imageProbe: returns `true` iff a usable icon image loads from the path.
    /// - Returns: `.resource` if any candidate yields an image, else `.fallback`.
    public static func resolve(
        candidateBundlePaths: [String],
        imageProbe: (String) -> Bool
    ) -> MenuBarIconResolution {
        for path in candidateBundlePaths where imageProbe(path) {
            return .resource
        }
        return .fallback
    }

    /// Non-trapping probe: does the resource bundle at `bundlePath` exist, load,
    /// and contain the `MenuBarIcon` asset? Uses `Bundle(path:)` which returns
    /// nil for a missing/corrupt bundle (the EXACT failure mode that crashed the
    /// app via `Bundle.module`) instead of trapping.
    public static func bundleAtPathHasIcon(_ bundlePath: String) -> Bool {
        guard let bundle = Bundle(path: bundlePath) else { return false }
        return bundle.image(forResource: iconResourceName) != nil
    }

    /// Ordered list of resource-bundle paths to probe for `Bundle.main`. The SPM
    /// resource bundle is copied into `Contents/Resources/` by the Makefile
    /// `app` target; the menu-bar PNGs are ALSO copied to top-level
    /// `Contents/Resources/` for the `Bundle.main` fallback. We return the SPM
    /// bundle path first, then the main bundle's own resource path, so a
    /// corrupt SPM bundle still finds the top-level copy. Pure given a
    /// `Bundle`; never traps.
    public static func candidateBundlePaths(forMainBundle main: Bundle) -> [String] {
        var paths: [String] = []
        if let resourceURL = main.resourceURL {
            // SPM executable-target resource bundle.
            paths.append(
                resourceURL.appendingPathComponent("TheBridge_TheBridge.bundle").path
            )
            // SPM library-target resource bundle (sibling).
            paths.append(
                resourceURL.appendingPathComponent("TheBridge_TheBridgeLib.bundle").path
            )
            // The .app's own Resources dir (top-level MenuBarIcon.png copy).
            paths.append(resourceURL.path)
        }
        return paths
    }

    /// Build the menu-bar icon image, NEVER trapping.
    ///
    /// 1. Try each candidate resource bundle via the non-trapping `Bundle(path:)`
    ///    probe and load `MenuBarIcon` from the first that has it.
    /// 2. Fall back to `Bundle.main.image(forResource:)` (top-level copy).
    /// 3. Fall back to the system SF Symbol.
    ///
    /// In every branch a usable `NSImage` is returned (the SF Symbol is a system
    /// asset that is always present), so the menu-bar item always renders.
    ///
    /// - Parameters:
    ///   - candidateBundlePaths: ordered resource-bundle paths to try (defaults
    ///     to `candidateBundlePaths(forMainBundle: .main)`).
    ///   - log: a logging sink (defaults to `NSLog`) so the degradation is
    ///     diagnosable in the unified log.
    /// - Returns: a template `NSImage` sized for the menu bar — resource image
    ///   when available, otherwise the SF Symbol fallback.
    @MainActor
    public static func makeMenuBarImage(
        candidateBundlePaths: [String]? = nil,
        log: (String) -> Void = { NSLog("%@", $0) }
    ) -> NSImage {
        let paths = candidateBundlePaths ?? Self.candidateBundlePaths(forMainBundle: .main)

        // 1. Resource bundles (non-trapping).
        for path in paths {
            if let bundle = Bundle(path: path),
               let image = bundle.image(forResource: iconResourceName) {
                return styleMenuBarImage(image)
            }
        }

        // 2. Bundle.main top-level copy (non-trapping).
        if let image = Bundle.main.image(forResource: iconResourceName) {
            return styleMenuBarImage(image)
        }

        // 3. SF Symbol fallback — the crash-loop killer. The previous code
        //    reached the trapping Bundle.module accessor; we degrade instead.
        log("[Bridge][MenuBarIcon] resource bundle / icon asset unloadable — "
            + "falling back to SF Symbol '\(fallbackSymbolName)'. The SPM resource "
            + "bundle may be missing Contents/ (a raced / corrupt staged update). "
            + "Recover with: clear ~/Library/Caches/<bundleid>/org.sparkle-project.Sparkle "
            + "staging + make install-copy (see docs/release/sparkle-troubleshooting.md).")
        let symbol = NSImage(
            systemSymbolName: fallbackSymbolName,
            accessibilityDescription: "The Bridge"
        ) ?? NSImage()
        return styleMenuBarImage(symbol)
    }

    /// Apply the shared menu-bar styling (template + size) to an image.
    @MainActor
    private static func styleMenuBarImage(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: iconPointSize, height: iconPointSize)
        image.isTemplate = true
        return image
    }
}
