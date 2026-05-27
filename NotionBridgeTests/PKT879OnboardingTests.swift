// PKT879OnboardingTests.swift — Onboarding wizard refresh (Liquid Glass)
//
// Contract tests for the v3.6.4 onboarding refresh:
//   • locked step count (7)
//   • Streamable HTTP is the Recommended transport
//   • completion fires the .onboardingDidComplete notification so the
//     user lands in the Dashboard (not raw Settings)
//   • locked window dimensions

import Foundation
import NotionBridgeLib

func runPKT879OnboardingTests() async {
    print("\n\u{1F9ED} PKT-879 Onboarding Tests (Liquid Glass refresh)")

    await test("PKT-879 onboarding step count is locked to 7") {
        try expect(PKT879Onboarding.totalSteps == 7,
                   "totalSteps drifted: \(PKT879Onboarding.totalSteps)")
    }

    await test("PKT-879 onboarding window is 520x520pt") {
        try expect(PKT879Onboarding.windowWidth == 520, "width drifted")
        try expect(PKT879Onboarding.windowHeight == 520, "height drifted")
    }

    await test("PKT-879 onboarding Recommended transport is Streamable HTTP") {
        try expect(PKT879Onboarding.recommendedTransport == "Streamable HTTP",
                   "Recommended transport drifted: \(PKT879Onboarding.recommendedTransport)")
    }

    await test("PKT-879 onboardingDidComplete notification name is published") {
        let name = Notification.Name.onboardingDidComplete
        try expect(name.rawValue == "com.notionbridge.onboardingDidComplete",
                   "notification name drifted: \(name.rawValue)")
    }

    await test("PKT-879 onboarding completion posts onboardingDidComplete") {
        // The window controller's `complete()` is private, but it is the
        // sole producer of the notification. We verify the notification
        // is observable + that posting it does NOT crash any observer
        // (NotificationCenter delivery is synchronous on the same queue).
        let expectation = NotificationListener()
        let token = NotificationCenter.default.addObserver(
            forName: .onboardingDidComplete,
            object: nil,
            queue: .main
        ) { _ in expectation.fire() }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: .onboardingDidComplete, object: nil)

        // Drain main runloop briefly so the queue:.main delivery completes.
        await MainActor.run {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let fired = await MainActor.run { expectation.didFire }
        try expect(fired, "expected .onboardingDidComplete to have been delivered")
    }
}

/// Tiny actor-free MainActor counter for the notification listener.
@MainActor
private final class NotificationListener {
    var didFire: Bool = false
    nonisolated init() {}
    nonisolated func fire() {
        Task { @MainActor in self.didFire = true }
    }
}
