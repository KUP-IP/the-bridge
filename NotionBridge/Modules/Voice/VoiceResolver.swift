// VoiceResolver.swift — WS-B (v2.3, PKT-803)
// NotionBridge · Modules · Voice
//
// Scaffold only — protocol + type declarations, zero implementation.
// Implemented in WS-E (voice resolver + paste-back). Engine choice per
// Decision D2 (v3 hub Decision Log): open-source local STT
// (OpenWhispr / Handy-class), offline, zero recurring cost.

import Foundation

// MARK: - Model

/// A speech-to-text transcription result handed to the resolver.
public struct Transcription: Sendable, Equatable {
    public let text: String
    public let confidence: Double
    public let locale: String

    public init(text: String, confidence: Double, locale: String) {
        self.text = text
        self.confidence = confidence
        self.locale = locale
    }
}

/// What the resolver decided to do with a transcription: either expand a
/// known snippet trigger or pass the literal text through to paste-back.
public enum ResolvedVoiceCommand: Sendable, Equatable {
    case snippet(id: String, expandedText: String)
    case literal(String)
}

public enum VoiceResolverError: Error, Equatable, Sendable {
    case emptyTranscription
    case lowConfidence(Double)
    case engineUnavailable(String)
}

// MARK: - Protocol

/// Resolves a transcription into a command and performs paste-back into
/// the frontmost app. Declaration-only in WS-B; WS-E provides the
/// conformer (STT engine binding, snippet lookup, paste injection).
public protocol VoiceResolving: Sendable {
    /// Map a transcription onto a snippet expansion or literal passthrough.
    func resolve(_ transcription: Transcription) async throws -> ResolvedVoiceCommand

    /// Inject the resolved text into the active input target.
    func pasteBack(_ command: ResolvedVoiceCommand) async throws
}
