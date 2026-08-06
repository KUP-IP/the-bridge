// MailTriageSignals.swift – deterministic mail triage heuristics
// TheBridge · Modules
//
// Pure Swift classifier used by mail_triage. No AppleScript, no LLM.
// Advisory only — never mutates Mail. Agents combine these signals with
// selective mail_read before calling organize/trash tools by messageId.

import Foundation

/// Recommendation bucket for a scanned message.
public enum MailTriageRecommendation: String, Sendable, Equatable {
    case preserve
    case candidateArchive
    case needsReview
}

/// One advisory triage row (identity + reasons + recommendation).
public struct MailTriageRow: Sendable, Equatable {
    public let messageId: String
    public let subject: String
    public let sender: String
    public let date: String
    public let read: String
    public let reasons: [String]
    public let recommendation: MailTriageRecommendation

    public init(
        messageId: String,
        subject: String,
        sender: String,
        date: String,
        read: String,
        reasons: [String],
        recommendation: MailTriageRecommendation
    ) {
        self.messageId = messageId
        self.subject = subject
        self.sender = sender
        self.date = date
        self.read = read
        self.reasons = reasons
        self.recommendation = recommendation
    }
}

/// Deterministic keyword / sender-domain signals for inbox triage.
public enum MailTriageSignals {

    /// Legal / financial / security / deadline / active-work keyword fragments
    /// matched case-insensitively against subject + sender (+ optional snippet).
    public static let preserveKeywords: [String] = [
        // legal
        "subpoena", "lawsuit", "court", "attorney", "legal notice", "summons",
        "cease and desist", "settlement", "affidavit",
        // financial
        "invoice", "tax", "irs", "w-2", "1099", "wire transfer", "payment due",
        "past due", "statement", "refund", "bank alert", " ach ", "routing number",
        // security
        "security alert", "password reset", "verification code", "2fa", "mfa",
        "suspicious sign", "new login", "verify your", "one-time code", "otp",
        // deadline / active work
        "deadline", "due by", "action required", "respond by", "rsvp",
        "offer letter", "contract", "nda", "closing date", "expires"
    ]

    /// Sender domains that usually warrant preserve/review (substring match).
    public static let preserveSenderHints: [String] = [
        "irs.gov", "treasury.gov", "paypal.com", "stripe.com", "plaid.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "schwab.com",
        "fidelity.com", "accounts.google.com", "appleid.apple.com",
        "login.microsoftonline.com", "id.me", "docusign.net", "hellosign.com"
    ]

    /// Newsletter / promo hints that, alone, lean toward archive when no preserve signal.
    /// Deliberately omits noreply@ / no-reply@ — those fire on transactional mail
    /// (shipping, receipts) and must not auto-promote to candidateArchive.
    public static let archiveHints: [String] = [
        "unsubscribe", "newsletter", "promo", "sale", "% off", "deal of",
        "weekly digest", "marketing"
    ]

    /// Classify one message from list-shaped fields. Snippet is optional body peek.
    public static func classify(
        messageId: String,
        subject: String,
        sender: String,
        date: String,
        read: String,
        snippet: String = ""
    ) -> MailTriageRow {
        let haystack = (subject + " " + sender + " " + snippet).lowercased()
        var reasons: [String] = []

        for kw in preserveKeywords where haystack.contains(kw) {
            reasons.append("preserve_keyword:\(kw.trimmingCharacters(in: .whitespaces))")
        }
        let senderLower = sender.lowercased()
        for hint in preserveSenderHints where senderLower.contains(hint) {
            reasons.append("preserve_sender:\(hint)")
        }

        var archiveHits: [String] = []
        for hint in archiveHints where haystack.contains(hint) {
            archiveHits.append("archive_hint:\(hint)")
        }

        // Preserve-biased policy (Red Team harden): unknown never becomes
        // candidateArchive. Only explicit archive hints with zero preserve
        // signals may recommend archive — and only when already read.
        let recommendation: MailTriageRecommendation
        if !reasons.isEmpty && !archiveHits.isEmpty {
            reasons.append(contentsOf: archiveHits)
            recommendation = .needsReview
        } else if !reasons.isEmpty {
            recommendation = .preserve
        } else if !archiveHits.isEmpty {
            reasons.append(contentsOf: archiveHits)
            let isRead = read.lowercased() == "true" || read.lowercased() == "yes"
            if isRead {
                recommendation = .candidateArchive
            } else {
                reasons.append("unread_with_archive_hints")
                recommendation = .needsReview
            }
        } else {
            // No preserve and no archive signal → always review (read or unread).
            let isRead = read.lowercased() == "true" || read.lowercased() == "yes"
            reasons.append(isRead ? "no_signals_read_default_review" : "no_signals_unread_default_review")
            recommendation = .needsReview
        }

        return MailTriageRow(
            messageId: messageId,
            subject: subject,
            sender: sender,
            date: date,
            read: read,
            reasons: reasons,
            recommendation: recommendation
        )
    }

    /// Classify a batch of list rows already shaped as field dictionaries.
    public static func classifyRows(_ rows: [[String: String]]) -> [MailTriageRow] {
        rows.map { r in
            classify(
                messageId: r["id"] ?? r["messageId"] ?? "",
                subject: r["subject"] ?? "",
                sender: r["sender"] ?? "",
                date: r["date"] ?? "",
                read: r["read"] ?? "",
                snippet: r["snippet"] ?? ""
            )
        }
    }
}
