// PermissionManagerTests.swift — Unit Tests for PermissionManager
// V1-02: Tests for TCC detection logic
//
// Note: TCC APIs cannot be fully mocked in unit tests.
// Direct-API grants (Accessibility, Screen Recording) always return
// a definitive result. Probe-based grants (Full Disk Access, Automation)
// depend on the test runner's actual TCC state.
// These tests validate state management, enum completeness, and
// that detection methods don't crash or block the main thread.

import Foundation
import TheBridgeLib

// MARK: - PermissionManager Tests

func runPermissionManagerTests() async {
    print("\n🔐 PermissionManager Tests")

    await test("Initial state is .unknown for all grants") {
        let manager = await PermissionManager()
        for grant in PermissionManager.Grant.allCases {
            let status = await manager.status(for: grant)
            try expect(status == .unknown,
                       "Grant \(grant.displayName) should start as .unknown, got \(status)")
        }
    }

    await test("Grant enum has all required TCC grants") {
        let grants = PermissionManager.Grant.allCases
        try expect(grants.count == 8, "Expected 8 grants, got \(grants.count)")
        try expect(grants.contains(.accessibility))
        try expect(grants.contains(.screenRecording))
        try expect(grants.contains(.fullDiskAccess))
        try expect(grants.contains(.automation))
        try expect(grants.contains(.notifications))
        try expect(grants.contains(.contacts))
        try expect(grants.contains(.reminders))
        try expect(grants.contains(.calendar))
    }

    await test("Grant display names are human-readable") {
        try expect(PermissionManager.Grant.accessibility.displayName == "Accessibility")
        try expect(PermissionManager.Grant.screenRecording.displayName == "Screen Recording")
        try expect(PermissionManager.Grant.fullDiskAccess.displayName == "Full Disk Access")
        try expect(PermissionManager.Grant.automation.displayName == "Automation")
        try expect(PermissionManager.Grant.notifications.displayName == "Notifications")
        try expect(PermissionManager.Grant.contacts.displayName == "Contacts")
        try expect(PermissionManager.Grant.reminders.displayName == "Reminders")
        try expect(PermissionManager.Grant.calendar.displayName == "Calendar")
    }

    await test("Grant IDs are unique") {
        let ids = PermissionManager.Grant.allCases.map(\.id)
        let uniqueIds = Set(ids)
        try expect(ids.count == uniqueIds.count, "All grant IDs should be unique")
    }

    await test("Grant auto/manual classification is correct") {
        try expect(PermissionManager.Grant.contacts.isAutoGrantable)
        try expect(PermissionManager.Grant.notifications.isAutoGrantable)
        try expect(PermissionManager.Grant.automation.isAutoGrantable)

        try expect(PermissionManager.Grant.accessibility.isAutoGrantable == false)
        try expect(PermissionManager.Grant.screenRecording.isAutoGrantable == false)
        try expect(PermissionManager.Grant.fullDiskAccess.isAutoGrantable == false)
        try expect(PermissionManager.Grant.reminders.isAutoGrantable == false)
        try expect(PermissionManager.Grant.calendar.isAutoGrantable == false)
    }

    await test("GrantStatus equality works correctly") {
        try expect(PermissionManager.GrantStatus.granted == .granted)
        try expect(PermissionManager.GrantStatus.denied == .denied)
        try expect(PermissionManager.GrantStatus.unknown == .unknown)
        try expect(PermissionManager.GrantStatus.partiallyGranted == .partiallyGranted)
        try expect(PermissionManager.GrantStatus.restartRecommended == .restartRecommended)
        try expect(PermissionManager.GrantStatus.granted != .denied)
        try expect(PermissionManager.GrantStatus.granted != .unknown)
        try expect(PermissionManager.GrantStatus.denied != .unknown)
    }

    await test("checkAll does not crash or block") {
        let manager = await PermissionManager()
        await manager.checkAll()
        // Direct-API grants should have definitive results
        let accStatus = await manager.accessibilityStatus
        let scrStatus = await manager.screenRecordingStatus
        try expect(accStatus != .unknown,
                   "Accessibility should resolve to granted or denied")
        try expect(scrStatus != .unknown,
                   "Screen Recording should resolve to granted or denied")
    }

    await test("Accessibility check returns definitive result") {
        let manager = await PermissionManager()
        await manager.checkAccessibility()
        let status = await manager.accessibilityStatus
        try expect(status == .granted || status == .denied,
                   "Expected granted or denied, got \(status)")
    }

    await test("Screen Recording check returns definitive result") {
        let manager = await PermissionManager()
        await manager.checkScreenRecording()
        let status = await manager.screenRecordingStatus
        try expect(status == .granted || status == .denied,
                   "Expected granted or denied, got \(status)")
    }

    await test("Full Disk Access probe does not crash") {
        let manager = await PermissionManager()
        await manager.checkFullDiskAccess()
        let status = await manager.fullDiskAccessStatus
        try expect(status == .granted || status == .denied,
                   "Expected granted or denied, got \(status)")
    }

    await test("Contacts check returns valid status") {
        let manager = await PermissionManager()
        await manager.checkContacts()
        let status = await manager.contactsStatus
        try expect(status == .granted || status == .denied || status == .unknown,
                   "Expected valid status, got \(status)")
    }

    await test("Automation check returns valid status with partial support") {
        let manager = await PermissionManager()
        await manager.checkAutomation()
        let status = await manager.automationStatus
        try expect(
            status == .granted || status == .denied || status == .partiallyGranted,
            "Expected granted/denied/partiallyGranted, got \(status)"
        )
    }

    await test("status(for:) returns correct property for each grant") {
        let manager = await PermissionManager()
        await manager.checkAll()
        try expect(await manager.status(for: .accessibility) == manager.accessibilityStatus)
        try expect(await manager.status(for: .screenRecording) == manager.screenRecordingStatus)
        try expect(await manager.status(for: .fullDiskAccess) == manager.fullDiskAccessStatus)
        try expect(await manager.status(for: .automation) == manager.automationStatus)
        try expect(await manager.status(for: .notifications) == manager.notificationStatus)
        try expect(await manager.status(for: .contacts) == manager.contactsStatus)
        try expect(await manager.status(for: .reminders) == manager.remindersStatus)
        try expect(await manager.status(for: .calendar) == manager.calendarStatus)
    }

    await test("checkAll populates lastCheckedAt and probe evidence") {
        let manager = await PermissionManager()
        await manager.checkAll()
        try expect(await manager.lastCheckedAt != nil, "Expected lastCheckedAt to be set after checkAll")
        // Sync grants only — notifications requires async checkNotifications(), not called by checkAll()
        let syncGrants = PermissionManager.Grant.allCases.filter { $0 != .notifications }
        for grant in syncGrants {
            try expect(await manager.evidence(for: grant) != nil, "Expected evidence for \(grant.displayName)")
        }
    }

    await test("recheckAllForTruth performs deterministic refresh pass") {
        let manager = await PermissionManager()
        await manager.checkAll()
        let before = await manager.lastCheckedAt
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms to ensure monotonic timestamp movement
        await manager.recheckAllForTruth()
        let after = await manager.lastCheckedAt
        try expect(after != nil, "Expected lastCheckedAt after recheckAllForTruth")
        if let before, let after {
            try expect(after >= before, "Expected recheckAllForTruth to refresh timestamp")
        }
    }

    await test("checkNotifications resolves to granted or denied or unknown") {
        let manager = await PermissionManager()
        await manager.checkNotifications()
        let status = await manager.notificationStatus
        try expect(
            status == .granted || status == .denied || status == .unknown,
            "Expected valid notification status, got \(status)"
        )
    }

    await test("checkAllAsync includes notification status") {
        let manager = await PermissionManager()
        await manager.checkAllAsync()
        // V3-QUALITY: In CLI context (no bundle), notification check is safely skipped
        if Bundle.main.bundleIdentifier != nil {
            let notifStatus = await manager.notificationStatus
            try expect(notifStatus != .unknown,
                       "Expected notification status resolved after checkAllAsync")
        }
        try expect(await manager.lastCheckedAt != nil,
                   "Expected lastCheckedAt set after checkAllAsync")
    }
}
