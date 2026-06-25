// VoiceMemoIntentElection.swift — primary-lane election (PKT-MEM-105)
// TheBridge · Modules · VoiceMemo
//
// One auto-execute lane per memo; secondary executable intents are suppressed
// and surfaced as review suggestions instead of fan-out writes.

import Foundation

public enum VoiceMemoIntentElection {

    private static let lanePriority: [VoiceMemoIntentKind: Int] = [
        .reminder: 4,
        .agentMemory: 3,
        .registryUpdate: 2,
        .memoryKeep: 1,
    ]

    /// Split intents into those eligible for auto-execute vs suppressed secondaries.
    public static func split(_ intents: [VoiceMemoIntent]) -> (execute: [VoiceMemoIntent], suppressed: [VoiceMemoIntent]) {
        let executable = intents.filter { $0.kind != .review }
        let reviews = intents.filter { $0.kind == .review }
        guard executable.count > 1 else {
            return (executable + reviews, [])
        }
        guard let primaryIndex = executable.indices.max(by: { isLowerPriority(executable[$0], executable[$1]) }) else {
            return (executable + reviews, [])
        }
        let primary = executable[primaryIndex]
        let suppressed = executable.enumerated().filter { $0.offset != primaryIndex }.map(\.element)
        return ([primary] + reviews, suppressed)
    }

    // Lane-priority-FIRST election (PKT-MEM-106 0a / SPEC §0.1): the elected primary
    // is chosen by lane priority (`reminder` > `agent_memory` > `registry_update` >
    // `memory_keep`); confidence only breaks ties WITHIN the same lane. Before 0a this
    // compared confidence before priority, which let a high-confidence registry lane
    // outrank a reminder — contradicting the M1/M5/M8 contracts.
    private static func isLowerPriority(_ a: VoiceMemoIntent, _ b: VoiceMemoIntent) -> Bool {
        let pa = lanePriority[a.kind] ?? 0
        let pb = lanePriority[b.kind] ?? 0
        if pa != pb { return pa < pb }
        if a.confidence != b.confidence { return a.confidence < b.confidence }
        return false
    }
}
