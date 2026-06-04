// SettingsWindow+Components.swift — Reusable Settings Components
// V3-QUALITY D1-D5: Extracted from SettingsWindow.swift monolith.
// Contains SensitivePathsEditor.

import SwiftUI

// MARK: - PKT-363 D3 + D4: Sensitive Paths Editor

/// Editable list of sensitive paths backed by ConfigManager.
/// Supports add/remove with validation, path normalization,
/// Restore Defaults (merge), and zero-path confirmation guard.
struct SensitivePathsEditor: View {
    @State private var paths: [String] = ConfigManager.shared.sensitivePaths
    @State private var newPath: String = ""
    @State private var validationError: String?
    @State private var isAddingPath = false
    @State private var showZeroPathWarning = false
    @State private var pendingRemoveIndex: Int?

    var body: some View {
        Section("Sensitive Paths") {
            if paths.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BridgeTokens.warn)
                        .font(.caption)
                    Text("No sensitive paths configured. All path protections are disabled.")
                        .font(.caption)
                        .foregroundStyle(BridgeTokens.warn)
                }
            } else {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    HStack {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.caption)
                            .foregroundStyle(BridgeColors.secondary)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button {
                            removePath(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(BridgeTokens.bad)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Add path controls
            if isAddingPath {
                HStack {
                    TextField("~/path or /absolute/path", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { addPath() }

                    Button("Add") { addPath() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button("Cancel") {
                        isAddingPath = false
                        newPath = ""
                        validationError = nil
                    }
                    .controlSize(.small)
                }

                if let error = validationError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(BridgeTokens.bad)
                }
            } else {
                Button {
                    isAddingPath = true
                    validationError = nil
                } label: {
                    Label("Add Path", systemImage: "plus.circle")
                        .font(.caption)
                }
                .controlSize(.small)
            }

            // PKT-363 D4: Restore Defaults — merges originals back without wiping custom
            Button("Restore Defaults") {
                paths = ConfigManager.shared.restoreDefaults()
            }
            .controlSize(.small)
            .font(.caption)
        }
        // PKT-363 D4: Zero-path confirmation guard
        .confirmationDialog(
            "Remove all path protections?",
            isPresented: $showZeroPathWarning,
            titleVisibility: .visible
        ) {
            Button("Remove Protection", role: .destructive) {
                if let index = pendingRemoveIndex {
                    paths.remove(at: index)
                    ConfigManager.shared.sensitivePaths = paths
                    pendingRemoveIndex = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoveIndex = nil
            }
        } message: {
            Text("This removes all sensitive path protections. Are you sure?")
        }
    }

    // MARK: Path Normalization

    /// Normalize absolute paths to ~/ form when applicable.
    /// e.g. ~/.ssh → ~/.ssh
    private func normalizePath(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed.hasPrefix(home) {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    // MARK: Validation + Add

    private func addPath() {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reject empty
        guard !trimmed.isEmpty else {
            validationError = "Path cannot be empty."
            return
        }

        // Must start with ~/ or /
        guard trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") else {
            validationError = "Path must start with ~/ or /."
            return
        }

        let normalized = normalizePath(trimmed)

        // No duplicates
        guard !paths.contains(normalized) else {
            validationError = "\(normalized) is already in the list."
            return
        }

        paths.append(normalized)
        ConfigManager.shared.sensitivePaths = paths
        newPath = ""
        validationError = nil
        isAddingPath = false
    }

    // MARK: Remove (with zero-path guard)

    private func removePath(at index: Int) {
        // PKT-363 D4: Confirm when removing the last path
        if paths.count == 1 {
            pendingRemoveIndex = index
            showZeroPathWarning = true
        } else {
            paths.remove(at: index)
            ConfigManager.shared.sensitivePaths = paths
        }
    }
}
