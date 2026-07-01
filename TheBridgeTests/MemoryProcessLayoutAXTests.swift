// MemoryProcessLayoutAXTests.swift — PKT-MEM-123 V1 Process layout AX manifest
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runMemoryProcessLayoutAXTests() async {
    print("\n🧭 Memory Process V1 layout AX (PKT-MEM-123)")

    let p = "bridge.settings.memory.process."

    await test("axV1_centerPane_exactConstant") {
        try expect(BridgeAXID.Memory.Process.centerPane == p + "centerPane", "center pane zone")
    }

    await test("axV1_intentTags_exactConstant") {
        try expect(BridgeAXID.Memory.Process.intentTags == p + "intentTags", "intent tags grid")
    }

    await test("axV1_intentTagCheckbox_suffixed") {
        try expect(BridgeAXID.Memory.Process.intentTagCheckbox("intent_a") == p + "intentTag.intent_a", "per-intent tag checkbox")
    }

    await test("axV1_confirmControls_exactConstants") {
        try expect(BridgeAXID.Memory.Process.confirmButton == p + "confirmButton", "confirm button")
        try expect(BridgeAXID.Memory.Process.confirmSummary == p + "confirmSummary", "confirm summary strip")
    }

    await test("axV1_transcriptToggle_exactConstants") {
        try expect(BridgeAXID.Memory.Process.transcriptExpand == p + "transcriptExpand", "transcript expand")
        try expect(BridgeAXID.Memory.Process.transcriptCollapse == p + "transcriptCollapse", "transcript collapse")
    }

    await test("axV1_activityDrawer_exactConstants") {
        try expect(BridgeAXID.Memory.Process.activityDrawer == p + "activityDrawer", "activity drawer")
        try expect(BridgeAXID.Memory.Process.activityDrawerToggle == p + "activityDrawerToggle", "drawer toggle")
        try expect(BridgeAXID.Memory.Process.activityDrawerCollapse == p + "activityDrawerCollapse", "drawer collapse strip")
    }

    await test("axV1_registryConfigureSheet_exactConstant") {
        try expect(BridgeAXID.Memory.Process.registryConfigureSheet == p + "registryConfigureSheet", "registry configure sheet")
    }

    await test("axV1_dryRun_exactConstant") {
        try expect(BridgeAXID.Memory.Process.dryRun == p + "dryRun", "dry-run button")
    }

    await test("axV1_optInUnderstand_exactConstants") {
        try expect(BridgeAXID.Memory.Process.processLocal == p + "processLocal", "process locally")
        try expect(BridgeAXID.Memory.Process.processCloud == p + "processCloud", "process cloud")
        try expect(BridgeAXID.Memory.Process.processPrompt == p + "processPrompt", "process prompt")
    }

    await test("axV1_harness_manifest_includesV1Zones") {
        let memory = SettingsUIValidationHarness.expectedIdentifiers[.memory] ?? []
        for zone in [
            BridgeAXID.Memory.Process.centerPane,
            BridgeAXID.Memory.Process.intentTags,
            BridgeAXID.Memory.Process.confirmButton,
            BridgeAXID.Memory.Process.confirmSummary,
            BridgeAXID.Memory.Process.activityDrawer,
            BridgeAXID.Memory.Process.registryConfigureSheet,
            BridgeAXID.Memory.Process.dryRun,
        ] {
            try expect(memory.contains(zone), "manifest registers V1 zone \(zone)")
        }
    }
}
