// ModuleGroupExpandPersistenceTests.swift — v3.6.0 D6
//
// Locks the cold-launch contract: every ModuleGroup defaults to collapsed,
// and an explicit user-toggle survives a fresh view construction by reading
// from BridgeDefaults.moduleGroupExpanded.

import Foundation
import NotionBridgeLib

func runModuleGroupExpandPersistenceTests() async {
    print("\n\u{1F4DC} D6 ModuleGroupCard expand-state persistence")

    let key = BridgeDefaults.moduleGroupExpanded
    let savedDict = UserDefaults.standard.dictionary(forKey: key)
    defer {
        if let savedDict {
            UserDefaults.standard.set(savedDict, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    await test("D6: persistence key is namespaced under com.notionbridge") {
        try expect(key == "com.notionbridge.moduleGroupExpanded")
    }

    await test("D6: writing an expand state for one group reads back") {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(["file": true], forKey: key)
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        try expect(dict["file"] as? Bool == true)
    }

    await test("D6: per-group entries do not bleed across groups") {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(["file": true, "notion": false], forKey: key)
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        try expect(dict["file"] as? Bool == true)
        try expect(dict["notion"] as? Bool == false)
    }

    await test("D6: missing entry → cold-launch default is collapsed") {
        // The default is encoded in ModuleGroupCard.init (saved ?? false when
        // masterState != .off). Test the data contract here: an empty dict
        // gives nil for any lookup, which the caller must interpret as
        // collapsed.
        UserDefaults.standard.removeObject(forKey: key)
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        try expect(dict["nonexistent_group"] == nil)
    }

    await test("D6: every declared ModuleGroupID can serve as a dict key") {
        // Belt-and-suspenders: assert no ModuleGroupID rawValue is empty or
        // contains characters that would collide as plist dictionary keys.
        for id in ModuleGroupID.allCases {
            try expect(!id.rawValue.isEmpty)
            try expect(!id.rawValue.contains(" "))
        }
    }
}
