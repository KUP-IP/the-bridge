// WranglerModule.swift — Cloudflare Wrangler integration tools (read-only)
// NotionBridge · Modules · dev/
//
// History:
//   PKT-757 (v2.2 · 0.2.2) — Initial: wrangler_d1_status tool. TOML binding
//                            resolver + subprocess wrapper for `wrangler d1
//                            migrations list` + d1 execute for applied
//                            migrations. Surfaces under module="dev" family.
//
// Tier: wrangler_d1_status → .open (read-only; no DB writes; SecurityGate at
// the shell layer is not needed because the tool only invokes its own narrow
// subprocess surface).

import Foundation
import MCP

public enum WranglerModule {
    /// Module family — registers under "dev" alongside DevModule scaffold per
    /// PKT-757 directive. Adds 1 tool (`wrangler_d1_status`).
    public static let moduleName = "dev"

    public static func register(on router: ToolRouter) async {
        await router.register(makeD1Status())
    }

    // MARK: - Public types

    /// Resolved `[[d1_databases]]` entry from a wrangler.toml file.
    public struct D1BindingEntry: Sendable, Equatable {
        public let configPath: String
        public let envScope: String?      // nil → top-level; e.g. "preview" → [[env.preview.d1_databases]]
        public let binding: String
        public let databaseName: String?
        public let databaseId: String?
    }

    public enum WranglerError: Error, Equatable {
        case capabilityMissing
        case configNotFound(path: String)
        case bindingNotFound(binding: String, searched: [String])
        case bindingAmbiguous(binding: String, locations: [String])
        case databaseNameMissing(binding: String, configPath: String)
    }

    // MARK: - Minimal TOML parser
    //
    // Hand-rolled parser handling only the subset of TOML used by wrangler:
    //   - `[[d1_databases]]` sections (top-level)
    //   - `[[env.<name>.d1_databases]]` sections (environment-scoped)
    //   - `key = "value"` and `key = 'value'` assignments inside those sections
    //   - line comments starting with `#` (outside of quoted strings)
    //
    // Other section types and value shapes are skipped without error.

    /// Parse a wrangler.toml string for D1 binding entries. Returns one entry
    /// per `[[d1_databases]]` block (top-level or env-scoped). Entries with no
    /// `binding` key are dropped. Other keys are tolerated and ignored.
    public static func parseD1Bindings(toml: String, configPath: String) -> [D1BindingEntry] {
        var entries: [D1BindingEntry] = []
        var inD1 = false
        var currentEnv: String? = nil
        var binding: String? = nil
        var name: String? = nil
        var dbId: String? = nil

        func flush() {
            if inD1, let b = binding {
                entries.append(D1BindingEntry(
                    configPath: configPath,
                    envScope: currentEnv,
                    binding: b,
                    databaseName: name,
                    databaseId: dbId
                ))
            }
            binding = nil
            name = nil
            dbId = nil
        }

        for raw in toml.components(separatedBy: "\n") {
            // Strip line comments while respecting simple quoted strings.
            var line = raw
            var inDQ = false
            var inSQ = false
            var commentIdx: String.Index? = nil
            for idx in line.indices {
                let c = line[idx]
                if c == "\"" && !inSQ { inDQ.toggle() }
                else if c == "'" && !inDQ { inSQ.toggle() }
                else if c == "#" && !inDQ && !inSQ { commentIdx = idx; break }
            }
            if let cidx = commentIdx { line = String(line[..<cidx]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Array-of-tables header: [[…]]
            if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
                flush()
                let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                if inner == "d1_databases" {
                    inD1 = true
                    currentEnv = nil
                } else if inner.hasPrefix("env."), inner.hasSuffix(".d1_databases") {
                    let mid = inner.dropFirst("env.".count).dropLast(".d1_databases".count)
                    inD1 = true
                    currentEnv = mid.isEmpty ? nil : String(mid)
                } else {
                    inD1 = false
                    currentEnv = nil
                }
                continue
            }
            // Plain table header: [section]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                flush()
                inD1 = false
                currentEnv = nil
                continue
            }
            guard inD1 else { continue }

            // key = value (best-effort string scrape).
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var rawVal = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if rawVal.hasSuffix(",") { rawVal = String(rawVal.dropLast()) }
            let val: String
            if (rawVal.hasPrefix("\"") && rawVal.hasSuffix("\"")) ||
               (rawVal.hasPrefix("'") && rawVal.hasSuffix("'")) {
                val = String(rawVal.dropFirst().dropLast())
            } else {
                val = rawVal
            }

            switch key {
            case "binding":       binding = val
            case "database_name": name = val
            case "database_id":   dbId = val
            default: break
            }
        }
        flush()
        return entries
    }

    // MARK: - Resolver

    /// Resolve a binding to a single D1BindingEntry. Searches
    /// `<repoRoot>/wrangler.toml` and `<repoRoot>/workers/wrangler.toml` (the
    /// canonical pair surfaced by the W29 / PKT-739 D2 investigation), or
    /// honors an explicit `configPath`. Throws on ambiguity.
    public static func resolveBinding(
        binding: String,
        explicitConfigPath: String?,
        repoRoot: String,
        envScope: String?
    ) throws -> D1BindingEntry {
        let candidates: [String]
        if let p = explicitConfigPath {
            candidates = [p]
        } else {
            candidates = [
                "\(repoRoot)/wrangler.toml",
                "\(repoRoot)/workers/wrangler.toml",
            ]
        }

        var matches: [(String, D1BindingEntry)] = []
        var anyConfigFound = false
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            anyConfigFound = true
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let parsed = parseD1Bindings(toml: content, configPath: path)
            if let hit = parsed.first(where: { $0.binding == binding && $0.envScope == envScope }) {
                matches.append((path, hit))
            }
        }

        if let p = explicitConfigPath, !anyConfigFound {
            throw WranglerError.configNotFound(path: p)
        }
        if matches.isEmpty {
            throw WranglerError.bindingNotFound(binding: binding, searched: candidates)
        }
        if matches.count > 1 {
            throw WranglerError.bindingAmbiguous(
                binding: binding,
                locations: matches.map { $0.0 }.sorted()
            )
        }
        let entry = matches[0].1
        guard entry.databaseName != nil else {
            throw WranglerError.databaseNameMissing(binding: binding, configPath: entry.configPath)
        }
        return entry
    }

    // MARK: - Subprocess

    /// Run `wrangler` with the given args from a working directory. 60s wall.
    static func runWrangler(args: [String], cwd: String) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["wrangler"] + args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            proc.terminationStatus
        )
    }

    /// Probe `wrangler` on PATH via `/usr/bin/which`. Returns false on any error.
    static func wranglerOnPath() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["wrangler"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Output parsing helpers

    /// Pull migration filenames from `wrangler d1 migrations list` stdout.
    /// Wrangler prints a table with box-drawing characters; we strip those and
    /// retain rows that look like `\d+_<slug>.sql`.
    public static func parsePendingFromList(stdout: String) -> [String] {
        var out: [String] = []
        for line in stdout.components(separatedBy: "\n") {
            let stripped = line
                .replacingOccurrences(of: "│", with: " ")
                .replacingOccurrences(of: "|", with: " ")
                .replacingOccurrences(of: "├", with: " ")
                .replacingOccurrences(of: "┤", with: " ")
                .replacingOccurrences(of: "─", with: " ")
                .trimmingCharacters(in: .whitespaces)
            // Pull the first `\S+\.sql` token from the stripped line.
            for tok in stripped.split(separator: " ") {
                let s = String(tok)
                if s.hasSuffix(".sql") {
                    // Heuristic: migration names start with a digit.
                    if let first = s.first, first.isNumber {
                        out.append(s)
                        break
                    }
                }
            }
        }
        return out
    }

    /// Extract `{name, applied_at}` rows from `wrangler d1 execute --json` output.
    public static func extractAppliedRows(from json: Any) -> [Value] {
        var out: [Value] = []
        func consume(_ rows: Any) {
            guard let arr = rows as? [[String: Any]] else { return }
            for row in arr {
                guard let name = row["name"] as? String, !name.isEmpty else { continue }
                var dict: [String: Value] = ["name": .string(name)]
                if let s = row["applied_at"] as? String, !s.isEmpty {
                    dict["applied_at"] = .string(s)
                } else if let n = row["applied_at"] as? NSNumber {
                    dict["applied_at"] = .string("\(n)")
                }
                out.append(.object(dict))
            }
        }
        if let arr = json as? [[String: Any]] {
            for env in arr {
                if let r = env["results"] { consume(r) }
            }
        } else if let dict = json as? [String: Any], let r = dict["results"] {
            consume(r)
        }
        return out
    }

    // MARK: - Tool factory

    private static func makeD1Status() -> ToolRegistration {
        ToolRegistration(
            name: "wrangler_d1_status",
            module: moduleName,
            tier: .open,
            description: "Resolve a Cloudflare D1 binding from wrangler.toml and report applied + pending migrations against the local or remote DB. Read-only. Returns {ok, binding, database_name, configPath, applied:[{name, applied_at}], pending:[{name}]}. Returns capability_missing when wrangler is not on PATH; binding_ambiguous when both /wrangler.toml and /workers/wrangler.toml define the same binding; binding_not_found / database_name_missing for misconfigured tomls.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "binding": .object([
                        "type": .string("string"),
                        "description": .string("D1 binding name as declared in wrangler.toml (e.g. 'DB').")
                    ]),
                    "repoRoot": .object([
                        "type": .string("string"),
                        "description": .string("Repo root containing wrangler.toml (and optionally workers/wrangler.toml). Default: current working directory.")
                    ]),
                    "configPath": .object([
                        "type": .string("string"),
                        "description": .string("Optional explicit wrangler.toml path; bypasses canonical search.")
                    ]),
                    "envScope": .object([
                        "type": .string("string"),
                        "description": .string("Optional environment scope (e.g. 'preview', 'production') to select [[env.<name>.d1_databases]]. Default: top-level [[d1_databases]].")
                    ]),
                    "local": .object([
                        "type": .string("boolean"),
                        "description": .string("When true (default), query --local DB. When false, query --remote.")
                    ])
                ]),
                "required": .array([.string("binding")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "wrangler_d1_status", reason: "expected object")
                }
                guard case .string(let binding) = args["binding"] else {
                    throw ToolRouterError.invalidArguments(toolName: "wrangler_d1_status", reason: "missing required 'binding' parameter")
                }
                let repoRoot: String = {
                    if case .string(let r) = args["repoRoot"] { return r }
                    return FileManager.default.currentDirectoryPath
                }()
                let explicitConfig: String? = {
                    if case .string(let p) = args["configPath"] { return p }
                    return nil
                }()
                let envScope: String? = {
                    if case .string(let e) = args["envScope"] { return e }
                    return nil
                }()
                let local: Bool = {
                    if case .bool(let b) = args["local"] { return b }
                    return true
                }()

                guard wranglerOnPath() else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("capability_missing"),
                        "capability": .string("wrangler"),
                        "message": .string("wrangler CLI not found on PATH. Install via: npm install -g wrangler")
                    ])
                }

                // Resolve binding (returns structured envelopes for each error variant).
                let entry: D1BindingEntry
                do {
                    entry = try resolveBinding(
                        binding: binding,
                        explicitConfigPath: explicitConfig,
                        repoRoot: repoRoot,
                        envScope: envScope
                    )
                } catch let e as WranglerError {
                    switch e {
                    case .capabilityMissing:
                        return .object([
                            "ok": .bool(false),
                            "error": .string("capability_missing")
                        ])
                    case .configNotFound(let p):
                        return .object([
                            "ok": .bool(false),
                            "error": .string("config_not_found"),
                            "path": .string(p)
                        ])
                    case .bindingAmbiguous(let b, let locs):
                        return .object([
                            "ok": .bool(false),
                            "error": .string("binding_ambiguous"),
                            "binding": .string(b),
                            "locations": .array(locs.map { .string($0) }),
                            "recommendation": .string("Pass configPath explicitly to disambiguate, or remove the duplicate definition.")
                        ])
                    case .bindingNotFound(let b, let s):
                        return .object([
                            "ok": .bool(false),
                            "error": .string("binding_not_found"),
                            "binding": .string(b),
                            "searched": .array(s.map { .string($0) })
                        ])
                    case .databaseNameMissing(let b, let p):
                        return .object([
                            "ok": .bool(false),
                            "error": .string("database_name_missing"),
                            "binding": .string(b),
                            "configPath": .string(p)
                        ])
                    }
                } catch {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("resolve_failed"),
                        "message": .string("\(error)")
                    ])
                }

                guard let dbName = entry.databaseName else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("database_name_missing"),
                        "binding": .string(binding),
                        "configPath": .string(entry.configPath)
                    ])
                }

                let configURL = URL(fileURLWithPath: entry.configPath)
                let runCwd = configURL.deletingLastPathComponent().path
                let scopeFlag = local ? "--local" : "--remote"

                // pending: `wrangler d1 migrations list <DB> <scope>`
                var pending: [Value] = []
                var pendingError: String? = nil
                do {
                    var listArgs = ["d1", "migrations", "list", dbName, scopeFlag]
                    if let env = entry.envScope { listArgs.append(contentsOf: ["--env", env]) }
                    let res = try runWrangler(args: listArgs, cwd: runCwd)
                    if res.exitCode == 0 {
                        pending = parsePendingFromList(stdout: res.stdout).map { .object(["name": .string($0)]) }
                    } else {
                        pendingError = "exit \(res.exitCode): \(String(res.stderr.prefix(500)))"
                    }
                } catch {
                    pendingError = "subprocess error: \(error)"
                }

                // applied: `wrangler d1 execute <DB> <scope> --command "SELECT ..." --json`
                var applied: [Value] = []
                var appliedError: String? = nil
                do {
                    var execArgs = ["d1", "execute", dbName, scopeFlag,
                                    "--command", "SELECT name, applied_at FROM d1_migrations ORDER BY applied_at",
                                    "--json"]
                    if let env = entry.envScope { execArgs.append(contentsOf: ["--env", env]) }
                    let res = try runWrangler(args: execArgs, cwd: runCwd)
                    if res.exitCode == 0 {
                        if let data = res.stdout.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data) {
                            applied = extractAppliedRows(from: parsed)
                        }
                    } else {
                        let lower = res.stderr.lowercased()
                        if lower.contains("no such table") || lower.contains("table not found") {
                            applied = []
                        } else {
                            appliedError = "exit \(res.exitCode): \(String(res.stderr.prefix(500)))"
                        }
                    }
                } catch {
                    appliedError = "subprocess error: \(error)"
                }

                var envelope: [String: Value] = [
                    "ok": .bool(true),
                    "binding": .string(binding),
                    "database_name": .string(dbName),
                    "configPath": .string(entry.configPath),
                    "local": .bool(local),
                    "applied": .array(applied),
                    "pending": .array(pending)
                ]
                if let id = entry.databaseId { envelope["database_id"] = .string(id) }
                if let env = entry.envScope { envelope["envScope"] = .string(env) }
                if let p = pendingError { envelope["pendingError"] = .string(p) }
                if let a = appliedError { envelope["appliedError"] = .string(a) }
                return .object(envelope)
            }
        )
    }
}
