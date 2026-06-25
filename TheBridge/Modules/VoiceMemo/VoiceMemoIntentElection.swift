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

    private static func isLowerPriority(_ a: VoiceMemoIntent, _ b: VoiceMemoIntent) -> Bool {
        if a.confidence != b.confidence { return a.confidence < b.confidence }
        let pa = lanePriority[a.kind] ?? 0
        let pb = lanePriority[b.kind] ?? 0
        if pa != pb { return pa < pb }
        return false
    }
}
