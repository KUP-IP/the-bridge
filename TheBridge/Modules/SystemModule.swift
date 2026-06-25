// SystemModule.swift – V1-05 System Tools
// TheBridge · Modules
//
// Three tools: system_info (open), process_list (open), notify (open).
// Uses sw_vers, sysctl, ps, and UserNotifications for macOS integration.

import AppKit
import Foundation
import MCP
import UserNotifications

// MARK: - SystemModule

/// Provides macOS system information, process listing, and notification tools.
public enum SystemModule {

    public static let moduleName = "system"

    /// Register all SystemModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. system_info – open
        await router.register(ToolRegistration(
            name: "system_info",
            module: moduleName,
            tier: .open,
            description: "Return the host Mac's model, OS version, RAM, uptime, plus homeDirectory, userName, and currentDirectory (use these instead of guessing /Users paths).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                var info: [String: Value] = [:]

                // OS version via sw_vers
                if let swVers = try? shellOutput("/usr/bin/sw_vers") {
                    let lines = swVers.components(separatedBy: "\n")
                    for line in lines {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 {
                            let key = parts[0].trimmingCharacters(in: .whitespaces)
                            let val = parts[1].trimmingCharacters(in: .whitespaces)
                            switch key {
                            case "ProductName": info["osName"] = .string(val)
                            case "ProductVersion": info["osVersion"] = .string(val)
                            case "BuildVersion": info["osBuild"] = .string(val)
                            default: break
                            }
                        }
                    }
                }

                // Hostname
                info["hostname"] = .string(ProcessInfo.processInfo.hostName)

                // FB-2: Environment paths — kills the recurring /Users/<guess> path-guess bug.
                // Agents read the real home/user/cwd instead of guessing.
                info["homeDirectory"] = .string(NSHomeDirectory())
                info["userName"] = .string(NSUserName())
                info["currentDirectory"] = .string(FileManager.default.currentDirectoryPath)

                // CPU info via sysctl
                if let cpuBrand = try? shellOutput("/usr/sbin/sysctl", args: ["-n", "machdep.cpu.brand_string"]) {
                    info["cpu"] = .string(cpuBrand.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                // CPU core count
                info["cpuCores"] = .int(ProcessInfo.processInfo.processorCount)
                info["cpuActiveCores"] = .int(ProcessInfo.processInfo.activeProcessorCount)

                // Physical memory
                let memBytes = ProcessInfo.processInfo.physicalMemory
                let memGB = Double(memBytes) / (1024 * 1024 * 1024)
                info["memoryGB"] = .double((memGB * 100).rounded() / 100)

                // System uptime
                let uptime = ProcessInfo.processInfo.systemUptime
                let days = Int(uptime) / 86400
                let hours = (Int(uptime) % 86400) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                info["uptime"] = .string("\(days)d \(hours)h \(minutes)m")
                info["uptimeSeconds"] = .double(uptime)

                // Hardware model via sysctl
                if let model = try? shellOutput("/usr/sbin/sysctl", args: ["-n", "hw.model"]) {
                    info["hardwareModel"] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                return .object(info)
            }
        ))

        // MARK: 2. process_list – open
        await router.register(ToolRegistration(
            name: "process_list",
            module: moduleName,
            tier: .open,
            description: "List running apps and background processes, sortable by cpu/mem/pid/name. Preferred over shell_exec ps.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filter": .object(["type": .string("string"), "description": .string("Optional process name filter (case-insensitive substring match)")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max processes to return (default: 50)")]),
                    "sortBy": .object(["type": .string("string"), "description": .string("Sort by: cpu, mem, pid, name (default: cpu)")])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let filter: String? = {
                    if case .object(let args) = arguments,
                       case .string(let f) = args["filter"] { return f }
                    return nil
                }()
                let limit: Int = {
                    if case .object(let args) = arguments,
                       case .int(let l) = args["limit"] { return l }
                    return 50
                }()
                let sortBy: String = {
                    if case .object(let args) = arguments,
                       case .string(let s) = args["sortBy"] { return s }
                    return "cpu"
                }()

                // ps output sorted by CPU by default
                let sortFlag: String
                switch sortBy.lowercased() {
                case "mem": sortFlag = "-m"
                case "pid": sortFlag = "-p"
                default: sortFlag = "-r" // sort by CPU
                }

                guard let output = try? shellOutput("/bin/ps", args: ["aux", sortFlag]) else {
                    return .object(["error": .string("Failed to execute ps")])
                }

                var lines = output.components(separatedBy: "\n")
                // Remove header
                let header = lines.removeFirst()
                _ = header // suppress unused warning

                var processes: [Value] = []
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }

                    // Parse ps aux columns: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND
                    let parts = trimmed.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                    if parts.count < 11 { continue }

                    let user = String(parts[0])
                    let pid = String(parts[1])
                    let cpu = String(parts[2])
                    let mem = String(parts[3])
                    let command = String(parts[10])

                    // Apply filter
                    if let f = filter {
                        let lowerFilter = f.lowercased()
                        if !command.lowercased().contains(lowerFilter) &&
                           !user.lowercased().contains(lowerFilter) {
                            continue
                        }
                    }

                    processes.append(.object([
                        "user": .string(user),
                        "pid": .string(pid),
                        "cpu": .string(cpu),
                        "mem": .string(mem),
                        "command": .string(command)
                    ]))

                    if processes.count >= limit { break }
                }

                return .object([
                    "count": .int(processes.count),
                    "sortedBy": .string(sortBy),
                    "processes": .array(processes)
                ])
            }
        ))

        // MARK: 3. notify – open
        await router.register(ToolRegistration(
            name: "notify",
            module: moduleName,
            tier: .open,
            description: "Display a macOS user notification (title + body + optional sound). Non-blocking. Optional openSettingsSection/openSettingsAnchor deep-link Memory/Inbox (or any Settings section) when the banner is tapped.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Notification title")]),
                    "body": .object(["type": .string("string"), "description": .string("Notification body text")]),
                    "sound": .object(["type": .string("string"), "description": .string("Optional sound name (e.g., 'Glass', 'Basso', 'Ping')")]),
                    "openSettingsSection": .object(["type": .string("string"), "description": .string("When set, tapping the notification opens this Settings section (e.g. Memory).")]),
                    "openSettingsAnchor": .object(["type": .string("string"), "description": .string("Optional sub-anchor within the section (e.g. inbox, notion, agent).")]),
                ]),
                "required": .array([.string("title"), .string("body")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let title) = args["title"],
                      case .string(let body) = args["body"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notify", reason: "missing 'title' or 'body'")
                }

                let soundName: String? = {
                    if case .string(let s) = args["sound"] { return s }
                    return nil
                }()
                let settingsSection: String? = {
                    if case .string(let s) = args["openSettingsSection"], !s.isEmpty { return s }
                    return nil
                }()
                let settingsAnchor: String? = {
                    if case .string(let s) = args["openSettingsAnchor"], !s.isEmpty { return s }
                    return nil
                }()

                do {
                    try await sendLocalNotification(
                        title: title,
                        body: body,
                        soundName: soundName,
                        settingsSection: settingsSection,
                        settingsAnchor: settingsAnchor
                    )
                    return .object([
                        "sent": .bool(true),
                        "title": .string(title),
                        "bodyLength": .int(body.utf8.count)
                    ])
                } catch let error as NotificationError {
                    return .object([
                        "sent": .bool(false),
                        "error": .string(error.localizedDescription)
                    ])
                } catch {
                    return .object([
                        "sent": .bool(false),
                        "error": .string("Notification delivery failed: \(error.localizedDescription)")
                    ])
                }
            }
        ))



    }

    // MARK: - Notification Helper

    private enum NotificationError: LocalizedError {
        case permissionDenied
        case authRequestFailed(String)
        case deliveryFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Notifications are denied for The Bridge. Enable them in System Settings > Notifications."
            case .authRequestFailed(let msg):
                return "Notification authorization failed: \(msg)"
            case .deliveryFailed(let msg):
                return "Notification delivery failed: \(msg)"
            }
        }
    }

    private static func sendLocalNotification(
        title: String,
        body: String,
        soundName: String?,
        settingsSection: String? = nil,
        settingsAnchor: String? = nil
    ) async throws {
        // Standalone test executables crash on UNUserNotificationCenter.currentNotificationCenter
        // outside an .app bundle. Fallback keeps tests stable while production app uses native API.
        if Bundle.main.bundleURL.pathExtension != "app" {
            try sendFallbackNotification(title: title, body: body, soundName: soundName)
            return
        }

        let center = UNUserNotificationCenter.current()

        // PKT-369 N2 workaround: requestAuthorization() is unreliable when authorization
        // was granted externally (e.g., via System Settings). It may throw UNErrorDomain
        // error 1 even though permission IS granted. Always use notificationSettings()
        // as the source of truth after attempting authorization.
        var settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            // Attempt authorization — ignore the result/error per N2 pattern
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // N2: Do NOT throw here — requestAuthorization error is unreliable.
                // Fall through to re-check notificationSettings() below.
            }
            // N2: Source of truth — re-check actual macOS grant state
            settings = await center.notificationSettings()
        }

        // Final gate: only proceed if actually authorized
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break // Authorized — proceed to send
        case .denied:
            throw NotificationError.permissionDenied
        case .notDetermined:
            // Still not determined after request — fall back to osascript
            try sendFallbackNotification(title: title, body: body, soundName: soundName)
            return
        @unknown default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if soundName != nil {
            content.sound = .default
        }
        if let settingsSection {
            content.userInfo = BridgeNotificationDeepLink.userInfo(
                section: settingsSection,
                anchor: settingsAnchor
            )
        }

        let request = UNNotificationRequest(
            identifier: "notionbridge-notify-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func sendFallbackNotification(title: String, body: String, soundName: String?) throws {
        let safeTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        if let soundName {
            let safeSound = soundName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script += " sound name \"\(safeSound)\""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? "osascript failed"
            throw NotificationError.deliveryFailed(stderr)
        }
    }

    // MARK: - Shell Helper

    /// Run a command and capture stdout.
    private static func shellOutput(_ executable: String, args: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
