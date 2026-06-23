// StagedUpdateValidator.swift — Sparkle update-path SPM-bundle integrity checks
// fix(sparkle): reject a corrupt resource bundle before it can crash-loop us
//
// CONTEXT. The 2026-06-05 incident was a Sparkle staged-update swap that left
// the app's SPM resource bundle `TheBridge_TheBridge.bundle` WITHOUT a
// `Contents/` dir — a structurally-corrupt bundle. The primary defense is the
// graceful-degradation fix at the menu-bar-icon load site
// (`MenuBarIconResolver`), which guarantees the app boots regardless. This file
// is the SECONDARY, best-effort defense: a pure, non-trapping predicate that
// reports whether an app bundle's SPM resource bundle is loadable, so the
// Sparkle delegate can:
//   • veto proceeding with an update when the CURRENTLY-RUNNING app's resource
//     bundle is already corrupt (a poisoned base that an install-on-top would
//     perpetuate), and
//   • log a hard warning if a structurally-corrupt resource bundle is observed.
//
// SPARKLE API LIMITATION (documented, see docs/release/sparkle-troubleshooting.md).
// Sparkle's only abort-capable delegate hook, `updater(_:shouldProceedWith
// Update:updateCheck:)`, runs BEFORE the update is downloaded/extracted, so the
// STAGED app bundle does not exist yet at that point and cannot be validated
// there. The post-extract hooks (`didExtractUpdate`, `willInstallUpdate`) are
// VOID notifications that cannot abort, and the actual atomic swap is performed
// by Sparkle's sandboxed Installer XPC service to which the running app has no
// reliable path. There is therefore no clean Sparkle seam to validate the
// staged bundle and abort the swap post-extract; we rely on (1) graceful
// degradation + (2) the install-copy hardening (PR #31) + (3) this running-app
// integrity gate + diagnostic logging.

import Foundation

/// Pure, non-trapping integrity checks for an app's SPM resource bundle. None of
/// these touch the SPM-synthesized `Bundle.module` accessor (which TRAPS on a
/// missing/corrupt bundle) — every lookup is an optional `Bundle(path:)` /
/// FileManager probe, so calling them can never abort the process.
public enum StagedUpdateValidator {
    /// The SPM resource bundle names the app ships. A `.bundle` is only valid if
    /// it loads via `Bundle(path:)` AND is non-empty (contains at least one
    /// resource file). The corrupt staged update left a `.bundle` that was an
    /// empty husk / could not load — that is what we flag.
    ///
    /// NOTE: we deliberately do NOT require a `Contents/` dir. A SwiftPM resource
    /// bundle is FLAT (resources at the bundle root, no `Contents/`) when built
    /// via `.build`, and only acquires a `Contents/` wrapper in some packagings.
    /// The reliable, context-independent corruption signal is loadable-and-
    /// non-empty, not the presence of `Contents/`.
    public static let resourceBundleNames = [
        "TheBridge_TheBridge.bundle",
        "TheBridge_TheBridgeLib.bundle",
    ]

    /// Result of validating an app bundle's SPM resource bundles.
    public enum Validation: Sendable, Equatable {
        /// Every expected resource bundle is present and structurally loadable.
        case ok
        /// One or more resource bundles are missing or structurally corrupt.
        /// Carries the offending bundle name + a human-readable reason.
        case corrupt(bundleName: String, reason: String)
    }

    /// Is the directory at `path` a structurally-valid loadable bundle? A bundle
    /// is considered corrupt (the incident's failure mode) if it exists on disk
    /// but `Bundle(path:)` cannot load it, OR it is an EMPTY husk (no resource
    /// files at all — the post-swap signature of a bundle that lost its
    /// contents). A flat SwiftPM bundle (resources at the root, no `Contents/`)
    /// is VALID; an empty directory is NOT.
    ///
    /// - Parameters:
    ///   - path: absolute path to the candidate `.bundle`.
    ///   - fileManager: injectable for tests (defaults to `.default`).
    /// - Returns: `true` iff the bundle loads and contains at least one resource.
    public static func isStructurallyValidBundle(
        atPath path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Non-trapping load probe (NEVER Bundle.module).
        guard Bundle(path: path) != nil else { return false }
        // Reject an empty husk: a loadable-but-contentless .bundle is the
        // post-corruption signature (the bundle dir survived the swap but its
        // contents — `Contents/` wrapper or flat resources — did not).
        let entries = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        let meaningful = entries.filter { $0 != ".DS_Store" }
        return !meaningful.isEmpty
    }

    /// Validate every expected SPM resource bundle inside an app bundle whose
    /// `Contents/Resources` directory is at `resourcesPath`. Returns `.ok` only
    /// if all are present and structurally valid; otherwise `.corrupt` naming
    /// the first offender.
    ///
    /// This is the pure seam the regression test drives with a synthetic
    /// resources dir (a present-but-Contents-less `.bundle`) to assert the
    /// corrupt case is detected without trapping.
    ///
    /// - Parameters:
    ///   - resourcesPath: absolute path to the app's `Contents/Resources`.
    ///   - expectedBundleNames: bundle names to require (defaults to the shipped set).
    ///   - fileManager: injectable for tests.
    public static func validateResources(
        atPath resourcesPath: String,
        expectedBundleNames: [String] = resourceBundleNames,
        fileManager: FileManager = .default
    ) -> Validation {
        for name in expectedBundleNames {
            let bundlePath = (resourcesPath as NSString).appendingPathComponent(name)
            // A bundle that is entirely absent is NOT treated as corruption here:
            // in some packagings only one of the two SPM bundles exists, and the
            // graceful-degradation path handles a genuinely-missing icon. We only
            // FLAG the dangerous case: a bundle that EXISTS but is structurally
            // corrupt (present-but-Contents-less / unloadable), because that is
            // precisely the bootable-but-crash-looping signature.
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: bundlePath, isDirectory: &isDir) && isDir.boolValue
            guard exists else { continue }
            if !isStructurallyValidBundle(atPath: bundlePath, fileManager: fileManager) {
                return .corrupt(
                    bundleName: name,
                    reason: "resource bundle exists but is structurally corrupt "
                        + "(missing Contents/ or unloadable) at \(bundlePath)"
                )
            }
        }
        return .ok
    }

    /// Validate the CURRENTLY-RUNNING app's resource bundles. Used by the Sparkle
    /// delegate's `shouldProceedWithUpdate` gate. Non-trapping; returns `.ok`
    /// when the running app's `Contents/Resources` can't be located (we don't
    /// block an update on an inconclusive probe).
    public static func validateRunningApp(
        mainBundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Validation {
        guard let resources = mainBundle.resourceURL?.path else { return .ok }
        return validateResources(atPath: resources, fileManager: fileManager)
    }
}
