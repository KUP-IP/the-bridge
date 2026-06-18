// PermissionsModuleTests.swift — fb-permissions
// TheBridge · Tests
//
// Unit tests for the unified `permissions_status` MCP tool. The TCC probes
// themselves are not exercised against live state (CI is headless and grant
// state is machine-dependent); instead the PURE assembler `PermissionsProbe`
// is driven with synthetic snapshots so the full wire contract — every
// category present, the {category, granted, status, settingsHint} shape, the
// summary rollup, and the GrantStatus→(granted,state) mapping — is locked
// deterministically. Registration / tier / annotation are asserted off the
// live ToolRegistration (no dispatch, mirroring SystemModuleTests).

import Foundation
import MCP
import TheBridgeLib

func runPermissionsModuleTests() async {
    print("\n\u{1F510} PermissionsModule Tests (fb-permissions)")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await PermissionsModule.register(on: router)

    // MARK: Registration / tier

    await test("PermissionsModule registers exactly 1 tool (permissions_status)") {
        let tools = await router.registrations(forModule: "permissions")
        try expect(tools.count == 1, "Expected 1 permissions tool, got \(tools.count)")
        try expect(tools.first?.name == "permissions_status", "Expected permissions_status")
    }

    await test("permissions_status is tier .open (read-only, no prompt)") {
        let tools = await router.registrations(forModule: "permissions")
        let tool = tools.first(where: { $0.name == "permissions_status" })!
        try expect(tool.tier == .open, "Expected .open, got \(tool.tier.rawValue)")
    }

    await test("permissions_status is annotated read-only + idempotent + non-destructive") {
        guard let ann = ToolAnnotationCatalog.annotations(for: "permissions_status") else {
            throw TestError.assertion("permissions_status missing explicit annotation")
        }
        try expect(ann.readOnlyHint == true, "must be read-only")
        try expect(ann.destructiveHint == false, "must be non-destructive")
        try expect(ann.idempotentHint == true, "must be idempotent")
        try expect(ann.requiresConfirmation == false, "open tier must not require confirmation")
    }

    await test("permissions_status input schema category key is camelCase") {
        let tools = await router.registrations(forModule: "permissions")
        let tool = tools.first(where: { $0.name == "permissions_status" })!
        guard case .object(let top) = tool.inputSchema,
              case .object(let props) = top["properties"] else {
            throw TestError.assertion("inputSchema is not a JSON-schema object")
        }
        try expect(props["category"] != nil, "expected optional 'category' property")
    }

    // MARK: GrantStatus → (granted, state) mapping

    await test("resolve: granted maps to (true, granted)") {
        let r = PermissionsProbe.resolve(.granted)
        try expect(r.granted == true && r.state == "granted")
    }

    await test("resolve: denied / unknown / partial / restart are not granted") {
        try expect(PermissionsProbe.resolve(.denied).granted == false)
        try expect(PermissionsProbe.resolve(.denied).state == "denied")
        try expect(PermissionsProbe.resolve(.unknown).granted == false)
        try expect(PermissionsProbe.resolve(.unknown).state == "unknown")
        try expect(PermissionsProbe.resolve(.partiallyGranted).granted == false)
        try expect(PermissionsProbe.resolve(.partiallyGranted).state == "partial")
        try expect(PermissionsProbe.resolve(.restartRecommended).granted == false)
        try expect(PermissionsProbe.resolve(.restartRecommended).state == "restartRecommended")
    }

    // MARK: Full-matrix coverage (the invisible-grant trap fix)

    await test("rows: covers all 8 TCC categories incl. Reminders + Calendar") {
        let rows = PermissionsProbe.rows(from: [:])  // empty → all default .unknown
        try expect(rows.count == PermissionManager.Grant.allCases.count,
                   "row count must equal Grant.allCases (\(PermissionManager.Grant.allCases.count)), got \(rows.count)")
        let cats = Set(rows.map(\.category))
        try expect(cats.contains("reminders"), "Reminders category missing")
        try expect(cats.contains("calendar"), "Calendar category missing")
        try expect(cats.contains("contacts"), "Contacts category missing")
        try expect(cats.contains("accessibility"), "Accessibility category missing")
        try expect(cats.contains("screenRecording"), "Screen Recording category missing")
        try expect(cats.contains("fullDiskAccess"), "Full Disk Access category missing")
        try expect(cats.contains("automation"), "Automation category missing")
        try expect(cats.contains("notifications"), "Notifications category missing")
    }

    await test("rows: missing category in snapshot defaults to unknown (never dropped)") {
        // Only supply reminders=granted; everything else must still appear as unknown.
        let rows = PermissionsProbe.rows(from: [.reminders: .granted])
        try expect(rows.count == PermissionManager.Grant.allCases.count)
        let reminders = rows.first(where: { $0.category == "reminders" })!
        try expect(reminders.granted == true && reminders.state == "granted")
        let calendar = rows.first(where: { $0.category == "calendar" })!
        try expect(calendar.granted == false && calendar.state == "unknown")
    }

    await test("rows: every category carries a non-empty settingsHint") {
        let rows = PermissionsProbe.rows(from: [:])
        for row in rows {
            try expect(!row.settingsHint.isEmpty, "\(row.category) settingsHint must not be empty")
            try expect(row.settingsHint.contains("System Settings"),
                       "\(row.category) hint should point at System Settings")
        }
    }

    // MARK: Payload wire shape

    await test("payload: emits categories array + summary rollup with missing list") {
        let snapshot: [PermissionManager.Grant: PermissionManager.GrantStatus] = [
            .accessibility: .granted,
            .reminders: .granted,
            .calendar: .denied,
            .contacts: .unknown
        ]
        let rows = PermissionsProbe.rows(from: snapshot)
        let payload = PermissionsProbe.payload(from: rows)
        guard case .object(let obj) = payload else {
            throw TestError.assertion("payload not an object")
        }
        guard case .array(let cats) = obj["categories"] else {
            throw TestError.assertion("missing categories array")
        }
        try expect(cats.count == PermissionManager.Grant.allCases.count)
        // Each category entry has the documented keys.
        guard case .object(let first) = cats.first else {
            throw TestError.assertion("category entry not an object")
        }
        for key in ["category", "displayName", "granted", "status", "settingsHint"] {
            try expect(first[key] != nil, "category entry missing key '\(key)'")
        }
        // Summary.
        guard case .object(let summary) = obj["summary"] else {
            throw TestError.assertion("missing summary object")
        }
        guard case .int(let granted) = summary["granted"],
              case .int(let total) = summary["total"],
              case .bool(let allGranted) = summary["allGranted"],
              case .array(let missing) = summary["missing"] else {
            throw TestError.assertion("summary shape wrong")
        }
        try expect(granted == 2, "expected 2 granted (accessibility + reminders), got \(granted)")
        try expect(total == PermissionManager.Grant.allCases.count)
        try expect(allGranted == false, "not all granted")
        // calendar(denied) + contacts(unknown) + the 4 unsupplied(unknown) = 6 missing.
        try expect(missing.count == total - 2, "missing count should be total-granted")
        let missingStrs = missing.compactMap { v -> String? in
            if case .string(let s) = v { return s }; return nil
        }
        try expect(missingStrs.contains("calendar"), "calendar should be in missing")
        try expect(missingStrs.contains("contacts"), "contacts should be in missing")
    }

    await test("payload: allGranted is true only when every category is granted") {
        var snap: [PermissionManager.Grant: PermissionManager.GrantStatus] = [:]
        for g in PermissionManager.Grant.allCases { snap[g] = .granted }
        let payload = PermissionsProbe.payload(from: PermissionsProbe.rows(from: snap))
        guard case .object(let obj) = payload,
              case .object(let summary) = obj["summary"],
              case .bool(let allGranted) = summary["allGranted"],
              case .array(let missing) = summary["missing"] else {
            throw TestError.assertion("payload shape wrong")
        }
        try expect(allGranted == true, "all granted should be true")
        try expect(missing.isEmpty, "no missing when all granted")
    }

    // MARK: SSOT — Grant.settingsHint + tccCategory

    await test("Grant.tccCategory equals rawValue for every case (wire contract pin)") {
        for g in PermissionManager.Grant.allCases {
            try expect(g.tccCategory == g.rawValue, "\(g) tccCategory must equal rawValue")
        }
    }

    await test("Grant.settingsHint is authored for every case") {
        for g in PermissionManager.Grant.allCases {
            try expect(!g.settingsHint.isEmpty, "\(g) has empty settingsHint")
        }
    }
}
