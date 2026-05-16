// MCPToolFactory.swift — v3.0·0.5 (PKT — agentic-usability)
// NotionBridge · Server
//
// Single source of truth for turning a ToolRegistration into the MCP
// `Tool` sent to clients. Previously this mapping was hand-duplicated in
// ServerManager.setup() (stdio) and SSETransport (streamable HTTP) — a
// drift class: a metadata change applied to one path silently shipped
// different tool descriptions to stdio vs remote-connector clients. Both
// transports now call `MCPToolFactory.tool(for:)`, so they are
// byte-identical by construction.
//
// The renderer folds optional ToolMetadata into the wire `description`
// (MCP carries no whenToUse/examples field) and populates the otherwise
// unused `Tool.Annotations.title`. Behavior-preserving for the 162
// metadata-less registrations: render() == the trimmed raw description.

import Foundation
import MCP

public enum BridgeToolDescriptionRenderer {

    /// Hard ceiling on a single rendered description. `tools/list` returns
    /// all ~162 at once; unbounded prose inflates every agent's context on
    /// every session. Density over length (audit Gap Analysis).
    public static let charBudget = 700

    /// Deterministic: same registration → same string, always.
    public static func render(_ reg: ToolRegistration) -> String {
        let core = reg.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = core.isEmpty ? [] : [core]

        if let m = reg.metadata {
            if !m.whenToUse.isEmpty {
                parts.append("When to use: " + m.whenToUse.joined(separator: "; "))
            }
            if !m.whenNotToUse.isEmpty {
                parts.append("Not for: " + m.whenNotToUse.joined(separator: "; "))
            }
            if !m.relatedTools.isEmpty {
                parts.append("Related: " + m.relatedTools.joined(separator: ", "))
            }
        }

        var s = parts.joined(separator: " — ")
        if s.count > charBudget {
            s = String(s.prefix(charBudget - 1)) + "\u{2026}"
        }
        return s
    }

    /// Human title. Explicit metadata title wins; else derive from the
    /// snake_case tool name ("notion_page_read" → "Notion Page Read").
    public static func title(_ reg: ToolRegistration) -> String {
        if let t = reg.metadata?.title, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return t
        }
        return reg.name
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public enum MCPToolFactory {

    /// The ONLY place a `ToolRegistration` becomes an MCP `Tool`.
    /// Both transports (ServerManager stdio + SSETransport HTTP) call this.
    public static func tool(for reg: ToolRegistration) -> Tool {
        let displayTitle = BridgeToolDescriptionRenderer.title(reg)
        var annotations = ToolAnnotationCatalog.resolved(for: reg.name).mcp
        annotations.title = displayTitle
        return Tool(
            name: reg.name,
            title: displayTitle,
            description: BridgeToolDescriptionRenderer.render(reg),
            inputSchema: reg.inputSchema,
            annotations: annotations
        )
    }
}
