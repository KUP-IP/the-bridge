// CursorNewRunWindow.swift — PKT-3.4.2 Wave 5a (Bridge v2.2)
// NotionBridge · UI
//
// Standalone window scene that hosts the "New Cursor Agent Run" form. Opened
// from the "+ New Run" button in the CursorAgentsWindow list pane. The form
// validates user input, computes an estimated cost from runtime + wall_cap,
// surfaces a generic redaction warning (per packet scope; the 3.4.3 ruleset
// will replace this), and dispatches the run via
// `CursorRuntime.shared.agentRun(...)`. Real sidecar invocation lands in
// PKT-3.4.1.W2 — today the call throws `notImplemented`, which we surface as
// an inline error in the form.
//
// Mirrors the OnboardingWindowController / SettingsWindowController pattern
// used elsewhere in Bridge: lazy NSWindow + NSHostingController, idempotent
// `show()` brings the existing window to front.

import AppKit
import SwiftUI

@MainActor
public final class CursorNewRunWindowController {

    public static let shared = CursorNewRunWindowController()

    private var window: NSWindow?

    public init() {}

    public func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = CursorNewRunView(onDismiss: { [weak self] in
            self?.close()
        })
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "New Cursor Agent Run"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 600, height: 600))
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .normal
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.close()
    }
}

// MARK: - SwiftUI form

struct CursorNewRunView: View {
    let onDismiss: () -> Void

    @State private var prompt: String = ""
    @State private var repoPath: String = ""
    @State private var branch: String = ""
    @State private var runtimeKind: CursorRuntimeKind = .cloud
    @State private var model: String = "composer-2"
    @State private var wallCapMinutes: Int = 30
    @State private var alwaysAllow: Bool = false
    @State private var submitting: Bool = false
    @State private var submitError: String? = nil

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRepo: String {
        repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var promptIsValid: Bool { !trimmedPrompt.isEmpty }
    private var repoIsValid: Bool { !trimmedRepo.isEmpty }
    private var wallCapIsValid: Bool { wallCapMinutes >= 1 && wallCapMinutes <= 240 }
    private var canSubmit: Bool { promptIsValid && repoIsValid && wallCapIsValid && !submitting }

    /// Heuristic estimate — the real cost comes from the sidecar in PKT-3.4.1.W2.
    private var estimatedCostCents: Int {
        switch runtimeKind {
        case .local: return 0
        case .cloud: return wallCapMinutes * 12 // ~$0.12/min for composer-2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    promptSection
                    repoSection
                    runtimeSection
                    modelSection
                    wallCapSection
                    costSection
                    redactionWarning
                    alwaysAllowSection
                    if let err = submitError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 540)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.tint)
            Text("New Cursor Agent Run").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Prompt").font(.subheadline).bold()
                Spacer()
                Text("required").font(.caption2).foregroundStyle(.secondary)
            }
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 100)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            if !promptIsValid {
                Text("Prompt is required.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var repoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Repository").font(.subheadline).bold()
            HStack {
                TextField("/path/to/repo", text: $repoPath).textFieldStyle(.roundedBorder)
                Button("Browse…") { browseForRepo() }
            }
            if !repoIsValid {
                Text("Repo path is required.").font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("Branch:").font(.caption).foregroundStyle(.secondary)
                TextField("(defaults to current)", text: $branch).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Runtime").font(.subheadline).bold()
            Picker("", selection: $runtimeKind) {
                Text("Cloud").tag(CursorRuntimeKind.cloud)
                Text("Local").tag(CursorRuntimeKind.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model").font(.subheadline).bold()
            TextField("composer-2", text: $model).textFieldStyle(.roundedBorder)
        }
    }

    private var wallCapSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wall cap (minutes)").font(.subheadline).bold()
            Stepper(value: $wallCapMinutes, in: 1...240, step: 5) {
                Text("\(wallCapMinutes) min").font(.body.monospacedDigit())
            }
            if !wallCapIsValid {
                Text("Wall cap must be between 1 and 240 minutes.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var costSection: some View {
        HStack {
            Text("Estimated cost").font(.subheadline).bold()
            Spacer()
            Text(String(format: "$%.2f", Double(estimatedCostCents) / 100.0))
                .font(.body.monospacedDigit())
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
    }

    private var redactionWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Redaction").font(.subheadline).bold()
            }
            Text("Your prompt and repo contents may be sent to the Cursor service. The structured prompt redaction ruleset lands in PKT-3.4.3; for now, audit your prompt for secrets before submitting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }

    private var alwaysAllowSection: some View {
        Toggle(isOn: $alwaysAllow) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Always allow this (repo, model, runtime) combination")
                    .font(.subheadline)
                Text("Skips the confirmation prompt for future runs with the same scope. Per-combination only — never global.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Button(action: submit) {
                if submitting {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else {
                    Text("Submit")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func browseForRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Repository Folder"
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
        }
    }

    private func submit() {
        submitting = true
        submitError = nil
        let promptCopy = trimmedPrompt
        let repoCopy = trimmedRepo
        let branchCopy = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelCopy = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeCopy = runtimeKind
        let estCostCopy = estimatedCostCents
        Task {
            do {
                _ = try await CursorRuntime.shared.agentRun(
                    prompt: promptCopy,
                    runtime: runtimeCopy,
                    model: modelCopy.isEmpty ? nil : modelCopy,
                    repoPath: repoCopy,
                    branch: branchCopy.isEmpty ? nil : branchCopy,
                    maxCostCents: estCostCopy
                )
                await MainActor.run {
                    submitting = false
                    onDismiss()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    submitting = false
                    submitError = message
                }
            }
        }
    }
}
