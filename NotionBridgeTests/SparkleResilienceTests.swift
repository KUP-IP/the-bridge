// SparkleResilienceTests.swift — fix(sparkle) regression coverage
// NotionBridge · Tests
//
// Guards the 2026-06-05 staged-update crash-loop fix. The live incident: a
// Sparkle staged-update swap left the SPM resource bundle
// `NotionBridge_NotionBridge.bundle` WITHOUT a `Contents/` dir → the
// SPM-synthesized `Bundle.module` accessor TRAPPED (`_assertionFailure`) at the
// menu-bar-icon load site → EXC_BREAKPOINT/SIGTRAP crash-loop on every launch.
//
// These tests drive the PURE, INJECTABLE guard logic with simulated
// missing/malformed resource-bundle paths and assert the code DEGRADES
// gracefully (returns a fallback / detects corruption) and NEVER traps. They
// touch no real `Bundle.module`, never corrupt /Applications, and build a
// synthetic present-but-Contents-less `.bundle` in a temp dir to reproduce the
// exact incident signature.
//
// Coverage:
//   • MenuBarIconResolver.resolve — missing/malformed bundle → .fallback (the
//     crash-loop killer); a probe that always traps would crash the suite, so a
//     passing run proves non-fatality. Plus: a healthy probe → .resource;
//     empty candidate list → .fallback; first-match-wins ordering.
//   • MenuBarIconResolver.bundleAtPathHasIcon — nonexistent / empty-dir path →
//     false (non-trapping).
//   • MenuBarIconResolver.candidateBundlePaths — derives the expected SPM +
//     main-bundle candidate paths.
//   • StagedUpdateValidator.isStructurallyValidBundle — present-but-Contents-
//     less .bundle (incident signature) → false; absent → false.
//   • StagedUpdateValidator.validateResources — corrupt bundle detected;
//     all-absent → .ok (degradation handles a genuinely-missing icon);
//     valid bundle → .ok.

import Foundation
import NotionBridgeLib

func runSparkleResilienceTests() async {
    print("\n\u{1F527} Sparkle Resilience Tests (fix(sparkle): staged-update crash-loop guard)")

    func makeTmpDir(_ tag: String) -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("nb-sparkle-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // ── MenuBarIconResolver.resolve: graceful degradation ──────────────────

    await test("MenuBarIconResolver: missing resource bundle degrades to .fallback (never traps)") {
        // Simulate a missing/malformed bundle: the probe always reports "no
        // image". If the code trapped instead of degrading, the suite would
        // crash here — a passing run is itself the non-fatality assertion.
        let result = MenuBarIconResolver.resolve(
            candidateBundlePaths: ["/nonexistent/NotionBridge_NotionBridge.bundle"],
            imageProbe: { _ in false }
        )
        try expect(result == .fallback, "Expected .fallback for a missing bundle, got \(result)")
    }

    await test("MenuBarIconResolver: empty candidate list degrades to .fallback") {
        let result = MenuBarIconResolver.resolve(candidateBundlePaths: [], imageProbe: { _ in true })
        try expect(result == .fallback, "Expected .fallback for no candidates, got \(result)")
    }

    await test("MenuBarIconResolver: a healthy candidate yields .resource") {
        let result = MenuBarIconResolver.resolve(
            candidateBundlePaths: ["/some/healthy.bundle"],
            imageProbe: { _ in true }
        )
        try expect(result == .resource, "Expected .resource when a candidate has the icon, got \(result)")
    }

    await test("MenuBarIconResolver: first valid candidate wins; corrupt-then-valid → .resource") {
        var probed: [String] = []
        let result = MenuBarIconResolver.resolve(
            candidateBundlePaths: ["/corrupt.bundle", "/valid.bundle"],
            imageProbe: { path in
                probed.append(path)
                return path == "/valid.bundle"
            }
        )
        try expect(result == .resource, "Expected .resource when a later candidate is valid")
        try expect(probed.contains("/corrupt.bundle"), "Expected the corrupt candidate to be probed first")
    }

    await test("MenuBarIconResolver: all-corrupt candidates → .fallback (never traps)") {
        let result = MenuBarIconResolver.resolve(
            candidateBundlePaths: ["/a.bundle", "/b.bundle", "/c.bundle"],
            imageProbe: { _ in false }
        )
        try expect(result == .fallback, "Expected .fallback when every candidate is corrupt")
    }

    // ── MenuBarIconResolver.bundleAtPathHasIcon: non-trapping probe ─────────

    await test("MenuBarIconResolver.bundleAtPathHasIcon: nonexistent path → false (non-trapping)") {
        let has = MenuBarIconResolver.bundleAtPathHasIcon("/definitely/not/here-\(UUID().uuidString).bundle")
        try expect(has == false, "Expected false for a nonexistent bundle path")
    }

    await test("MenuBarIconResolver.bundleAtPathHasIcon: empty dir → false (no icon)") {
        let dir = makeTmpDir("emptybundle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let has = MenuBarIconResolver.bundleAtPathHasIcon(dir.path)
        try expect(has == false, "Expected false for an empty/iconless directory")
    }

    await test("MenuBarIconResolver.candidateBundlePaths: derives SPM + main candidates") {
        let tmpApp = makeTmpDir("app")
        let resources = tmpApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpApp) }
        // A real Bundle pointed at our temp app dir so resourceURL resolves.
        guard let bundle = Bundle(path: tmpApp.path) else {
            throw TestError.assertion("Bundle(path:) returned nil for temp app dir")
        }
        let paths = MenuBarIconResolver.candidateBundlePaths(forMainBundle: bundle)
        // Bundle.resourceURL for a non-.app dir resolves to the dir itself; the
        // contract we lock is that the SPM bundle names are present in the list.
        try expect(paths.contains(where: { $0.hasSuffix("NotionBridge_NotionBridge.bundle") }),
                   "Expected the executable-target SPM bundle in candidates")
        try expect(paths.contains(where: { $0.hasSuffix("NotionBridge_NotionBridgeLib.bundle") }),
                   "Expected the library-target SPM bundle in candidates")
    }

    // ── StagedUpdateValidator: incident-signature detection ────────────────

    await test("StagedUpdateValidator: empty-husk .bundle → invalid (incident signature)") {
        // Reproduce the EXACT incident: a .bundle dir that survived the swap but
        // lost its contents (an empty husk). Must be detected as corrupt without
        // trapping.
        let root = makeTmpDir("corruptsig")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("NotionBridge_NotionBridge.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        // Intentionally EMPTY — no resources, no Contents/.
        let valid = StagedUpdateValidator.isStructurallyValidBundle(atPath: bundle.path)
        try expect(valid == false, "Expected an empty-husk .bundle to be invalid")
    }

    await test("StagedUpdateValidator: absent .bundle → invalid (non-trapping)") {
        let valid = StagedUpdateValidator.isStructurallyValidBundle(
            atPath: "/nope/NotionBridge_NotionBridge.bundle-\(UUID().uuidString)"
        )
        try expect(valid == false, "Expected an absent .bundle to be invalid")
    }

    await test("StagedUpdateValidator: flat .bundle with resources → valid (no Contents/ required)") {
        // A SwiftPM resource bundle is FLAT (resources at the root, no
        // Contents/) when built via .build — that must NOT be flagged corrupt.
        let root = makeTmpDir("validbundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("NotionBridge_NotionBridge.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "icon".write(to: bundle.appendingPathComponent("MenuBarIcon.png"), atomically: true, encoding: .utf8)
        let valid = StagedUpdateValidator.isStructurallyValidBundle(atPath: bundle.path)
        try expect(valid == true, "Expected a flat .bundle WITH resource files to be valid")
    }

    await test("StagedUpdateValidator.validateResources: corrupt bundle in resources → .corrupt") {
        let resources = makeTmpDir("res-corrupt")
        defer { try? FileManager.default.removeItem(at: resources) }
        // Present-but-Contents-less SPM bundle = the poisoned-resources signature.
        let bundle = resources.appendingPathComponent("NotionBridge_NotionBridge.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let result = StagedUpdateValidator.validateResources(atPath: resources.path)
        if case .corrupt(let name, _) = result {
            try expect(name == "NotionBridge_NotionBridge.bundle", "Expected the corrupt bundle named, got \(name)")
        } else {
            throw TestError.assertion("Expected .corrupt for a Contents-less SPM bundle, got \(result)")
        }
    }

    await test("StagedUpdateValidator.validateResources: all bundles absent → .ok (degradation handles missing icon)") {
        let resources = makeTmpDir("res-empty")
        defer { try? FileManager.default.removeItem(at: resources) }
        let result = StagedUpdateValidator.validateResources(atPath: resources.path)
        try expect(result == .ok, "Expected .ok when no SPM bundle exists (a missing icon degrades, not corrupts), got \(result)")
    }

    await test("StagedUpdateValidator.validateResources: well-formed bundles → .ok") {
        let resources = makeTmpDir("res-ok")
        defer { try? FileManager.default.removeItem(at: resources) }
        for name in StagedUpdateValidator.resourceBundleNames {
            let contents = resources
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        }
        let result = StagedUpdateValidator.validateResources(atPath: resources.path)
        try expect(result == .ok, "Expected .ok for well-formed resource bundles, got \(result)")
    }

    await test("StagedUpdateValidator.validateRunningApp: never traps on the live main bundle") {
        // The test binary's main bundle has no SPM .bundle dirs; this must
        // return .ok (absent ≠ corrupt) and never trap. Locks non-fatality on
        // the real Bundle.main path the Sparkle delegate uses.
        let result = StagedUpdateValidator.validateRunningApp()
        try expect(result == .ok, "Expected .ok validating the test runner's main bundle, got \(result)")
    }
}
