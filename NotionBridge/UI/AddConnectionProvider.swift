// AddConnectionProvider.swift — small shared provider enum for the onboarding
// "Add connection" sheet.
//
// Settings Redesign (PKT-connection): extracted verbatim from the now-deleted
// ConnectionsManagementView.swift (a dead Settings view) because the type is
// still referenced by OnboardingWindow.swift. Deleting the dead view orphaned
// this enum; relocating it here keeps onboarding compiling without resurrecting
// the dead view or its unused AddWorkspaceConnectionSheet.

import Foundation

/// UEP-004: Provider-agnostic connection sheet provider (Notion-only today).
enum AddConnectionProvider: String, CaseIterable, Identifiable {
    case notion = "Notion"

    var id: String { rawValue }

    var namePlaceholder: String {
        "Workspace name (e.g. Work, Personal)"
    }

    var tokenPlaceholder: String {
        "Notion API token (ntn_...)"
    }

    var helpURL: URL? {
        URL(string: "https://www.notion.so/profile/integrations")
    }

    var helpLabel: String {
        "Create a Notion integration at notion.so"
    }

    var saveButtonLabel: String {
        "Test & Save"
    }
}
