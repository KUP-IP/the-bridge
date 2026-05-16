// BridgeToolError.swift — v3.0·0.5 (PKT — agentic-usability)
// NotionBridge · Server
//
// Centralized parameter-misnomer recovery. AGENT_FEEDBACK logged repeated
// 2–3-call retry storms where an agent guessed a plausible-but-wrong
// param key and got a generic "missing 'x'" with no recovery hint — it
// had to read the .swift source to learn the real key (impossible for a
// source-less connector consumer).
//
// This is applied ONCE in ToolRouter.dispatchFormatted's error path, so
// every one of the 162 tools gets did-you-mean recovery for free — no
// per-handler edits (doctrine: centralize over N-site edits).

import Foundation

public enum BridgeToolAliases {

    /// Known wrong→right param keys, harvested from AGENT_FEEDBACK.md
    /// evidence. Extend as new misnomers are observed. Value is the
    /// canonical key the handlers actually read.
    public static let map: [String: String] = [
        "content": "text",            // notion_comment_create (logged ×2)
        "commentMarkdown": "text",    // addCommentToDiscussion (logged)
        "commentText": "text",
        "data_source_id": "dataSourceId",  // notion_datasource_get (logged)
        "datasource_id": "dataSourceId",
        "dataSource": "dataSourceId",
        "page": "pageId",
        "page_id": "pageId",
        "block": "blockId",
        "block_id": "blockId",
        // v3.0·0.5: keys renamed to camelCase this packet — legacy
        // snake forms still accepted by handlers; steer new callers.
        "zip_code": "zipCode",
        "credential_service": "credentialService",
        "credential_account": "credentialAccount",
        "idempotency_key": "idempotencyKey",
    ]

    /// Given the keys an agent actually sent, return a one-line
    /// "did you mean: a→b, c→d" hint, or nil if none look like a known
    /// misnomer. Pure + deterministic (sorted) so it is test-stable.
    public static func didYouMean(providedKeys: [String]) -> String? {
        let hits = providedKeys
            .compactMap { k -> String? in map[k].map { "\(k)→\($0)" } }
            .sorted()
        guard !hits.isEmpty else { return nil }
        return "did you mean: " + hits.joined(separator: ", ")
    }
}
