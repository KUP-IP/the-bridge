// ConfigManagerTests.swift — PKT-363: Config fallback + path validation tests
// TheBridge · Tests
//
// HERMETIC (v3.6.1): these tests read/write through ConfigManager.shared, which
// honors the BRIDGE_CONFIG_PATH override the harness sets to a temp file before
// any test runs (see main.swift). They never touch the user's real
// ~/.config/.../config.json, and they are agnostic to the config dir name
// (notion-bridge vs the-bridge) because they resolve the path via
// ConfigManager.shared.configFileURL rather than hardcoding it.

import Foundation
import TheBridgeLib

func runConfigManagerTests() async {
    print("\n🔧 ConfigManager Tests (PKT-363)")

    // Resolve the active config path from the manager itself — follows the
    // BRIDGE_CONFIG_PATH override, so this is the temp file under test.
    let configPath = ConfigManager.shared.configFileURL

    // Test 1: Config fallback — sensitivePaths returns defaults when key is missing/malformed
    await test("Config fallback returns 5 defaults when sensitivePaths key is absent") {
        let fm = FileManager.default
        try? fm.createDirectory(at: configPath.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let originalJSON: [String: Any] = {
            guard let d = try? Data(contentsOf: configPath),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return j
        }()

        var stripped = originalJSON
        stripped.removeValue(forKey: "sensitivePaths")
        let strippedData = try JSONSerialization.data(withJSONObject: stripped, options: [.prettyPrinted])
        try strippedData.write(to: configPath, options: .atomic)

        let paths = ConfigManager.shared.sensitivePaths
        try expect(paths.count == 5, "Expected 5 default paths, got \(paths.count)")
        try expect(paths.contains("~/.ssh"), "Expected ~/.ssh in defaults")
        try expect(paths.contains("~/.aws"), "Expected ~/.aws in defaults")
        try expect(paths.contains("~/.gnupg"), "Expected ~/.gnupg in defaults")
        try expect(paths.contains("~/.config"), "Expected ~/.config in defaults")
        try expect(paths.contains("~/Library/Keychains"), "Expected ~/Library/Keychains in defaults")
    }

    // Test 2: Path validation — write/read round-trip + restoreDefaults merge
    await test("Path normalization and validation rules") {
        let original = ConfigManager.shared.sensitivePaths

        let testPaths = ["~/.ssh", "~/.custom-test-path"]
        ConfigManager.shared.sensitivePaths = testPaths
        let readBack = ConfigManager.shared.sensitivePaths
        try expect(readBack.count == 2, "Expected 2 paths, got \(readBack.count)")
        try expect(readBack.contains("~/.ssh"), "Expected ~/.ssh")
        try expect(readBack.contains("~/.custom-test-path"), "Expected ~/.custom-test-path")

        try expect(ConfigManager.defaultSensitivePaths.count == 5, "Expected 5 default paths")

        ConfigManager.shared.sensitivePaths = ["~/.custom-only"]
        let merged = ConfigManager.shared.restoreDefaults()
        try expect(merged.contains("~/.custom-only"), "Custom path should survive merge")
        try expect(merged.contains("~/.ssh"), "Default ~/.ssh should be restored")
        try expect(merged.count == 6, "Expected 6 paths (1 custom + 5 defaults), got \(merged.count)")

        ConfigManager.shared.sensitivePaths = original
    }

    // Test 3 (v4 audit #8): config.json may hold secrets (Notion token, Stripe
    // key, OAuth JWKS) — it must be owner-only (0o600), never world-readable.
    // Any write through ConfigManager (here, the sensitivePaths setter →
    // writeConfig) must chmod the FINAL file to 0o600.
    await test("config.json is written with 0o600 (owner-only) perms — secrets not world-readable") {
        let original = ConfigManager.shared.sensitivePaths
        // Force a write through the standard path.
        ConfigManager.shared.sensitivePaths = ["~/.perm-check"]

        let attrs = try FileManager.default.attributesOfItem(atPath: configPath.path)
        guard let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue else {
            throw TestError.assertion("config.json has no POSIX permissions attribute")
        }
        // Mask to the permission bits and require exactly rw-------.
        try expect(perms & 0o777 == 0o600,
                   "config.json perms must be 0o600, got 0o\(String(perms & 0o777, radix: 8))")

        ConfigManager.shared.sensitivePaths = original
    }
}
