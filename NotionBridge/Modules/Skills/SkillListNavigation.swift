// SkillListNavigation.swift — PKT-1003 Skills Truth-Up · Wave D
// NotionBridge · Modules · Skills
//
// Pure navigation math for the Skills detail-header up/down arrows. The view
// computes the visible (filtered + grouped) skill names in on-screen order and
// asks this helper for the previous/next selection. Kept out of the view so it
// is unit-testable without a SwiftUI render.

import Foundation

public enum SkillListNavigation: Sendable {
    /// The name `delta` steps from `name` within `order` (the visible list in
    /// display order). Returns nil at a boundary (no wrap) or when `name` is not
    /// present in the visible list. `delta = -1` is "previous", `+1` is "next".
    public static func target(from name: String, delta: Int, in order: [String]) -> String? {
        guard let i = order.firstIndex(of: name) else { return nil }
        let j = i + delta
        guard j >= 0, j < order.count else { return nil }
        return order[j]
    }
}
