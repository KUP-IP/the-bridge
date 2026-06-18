// CommandsSection.swift — Settings → Commands page body (the command manager).
// PKT-6 UI v3.5 · Commands redesign (bundle-2) · Settings-Redesign PKT-orders ·
// Commands-v2 fold (2026-06-12):
//
// Was a standalone hero-led pane; now the Commands page body. The hero + its
// master switch + stat tiles are gone (the composite header + meta row carry
// them). The outer ScrollView and the `minHeight: 560` floor are removed so ONLY
// the two master-detail columns scroll — the editor owns the full height.
//
// The global-shortcut control USED to sit here as a slim inline banner above the
// editor. Per Commands-v2 (`page-commands.jsx` `.cmdp-meta`) the recordable ⌃⌘B
// keycap was FOLDED UP into the composite slim meta row (OrdersSection.metaBar),
// so this body is now just the editor — no standalone shortcut card below the
// header. The recorder/status machinery (CommandsController observation,
// HotkeyRecorderField, CommandsSettingsStatus mapping) moved with it.
//
// The `commands` array + `selectedSlug` are owned by the composite (OrdersSection)
// and passed in as bindings so the meta-row stat counts stay live with this
// pane's CRUD. Every CommandStore binding is preserved verbatim: CRUD, the
// icon/color picker, favorite-slot assignment, and clipboard-copy.

import AppKit
import SwiftUI

public struct CommandsSection: View {
    @Binding private var commands: [CommandStore.Command]
    @Binding private var selectedSlug: String?

    public init(
        commands: Binding<[CommandStore.Command]>,
        selectedSlug: Binding<String?>
    ) {
        self._commands = commands
        self._selectedSlug = selectedSlug
    }

    public var body: some View {
        // No outer ScrollView and no minHeight floor: the master-detail owns the
        // full height; only its two columns scroll internally (fix U4). The
        // shortcut recorder is no longer here — it folded into the meta row.
        CommandsEditorView(
            commands: $commands,
            selectedSlug: $selectedSlug
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.clear)
    }
}
