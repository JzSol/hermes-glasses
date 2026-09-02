//
// AdamVoiceFeedbackPolicy.swift
//
// Foundation-only policy vocabulary for Adam's voice presentation. Keeping
// this separate from SwiftUI and AVFoundation makes the phase contract easy
// to exercise in a standalone test target.
//

import Foundation

enum AdamVoiceFeedbackState: Equatable, Sendable {
    case idle
    case connecting
    case reconnecting
    case armed
    case wakeAcknowledged
    case hearingSpeech
    case paused
    case transcribing
    case transcriptReady
    case thinking
    case preparingVoice
    case speaking
    case failed
}

enum AdamPresentationFeedbackPhase: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case hearingSpeech
    case paused
    case transcribing
    case transcriptReady
    case thinking
    case preparingVoice
    case speaking
    case failure

    var usesWaveform: Bool {
        switch self {
        case .listening, .hearingSpeech, .paused:
            return true
        default:
            return false
        }
    }
}

enum AdamSensoryFeedbackEvent: Equatable, Sendable {
    case idle
    case wakeCueStarted
    case transcriptionStarted
}

enum AdamVoiceFeedbackPolicy {
    static func phase(
        for state: AdamVoiceFeedbackState
    ) -> AdamPresentationFeedbackPhase {
        switch state {
        case .idle: return .idle
        case .connecting, .reconnecting: return .connecting
        case .armed, .wakeAcknowledged: return .listening
        case .hearingSpeech: return .hearingSpeech
        case .paused: return .paused
        case .transcribing: return .transcribing
        case .transcriptReady: return .transcriptReady
        case .thinking: return .thinking
        case .preparingVoice: return .preparingVoice
        case .speaking: return .speaking
        case .failed: return .failure
        }
    }
}

/// A pure, one-shot grace-period gate for an active command that has paused.
/// The session owns the task; this value owns the deadline and stale-ticket
/// rules so a cancelled or resumed utterance cannot be submitted late.
struct AdamPauseGate: Equatable, Sendable {
    static let gracePeriod: TimeInterval = 15

    private(set) var deadline: Date?
    private var generation: UInt64 = 0
    private var consumed = false

    var isPaused: Bool { deadline != nil && !consumed }

    mutating func begin(at now: Date) -> UInt64 {
        generation &+= 1
        deadline = now.addingTimeInterval(Self.gracePeriod)
        consumed = false
        return generation
    }

    mutating func reset() {
        generation &+= 1
        deadline = nil
        consumed = false
    }

    func isDue(ticket: UInt64, at now: Date) -> Bool {
        ticket == generation
            && !consumed
            && deadline.map { now >= $0 } == true
    }

    mutating func consumeTimeout(ticket: UInt64, at now: Date) -> Bool {
        guard isDue(ticket: ticket, at: now) else { return false }
        consumed = true
        deadline = nil
        return true
    }
}

enum AdamFinishPhrasePolicy {
    private static let finishPhrases: Set<[String]> = [
        ["thats", "it"],
        ["that", "s", "it"],
        ["that", "is", "it"],
        ["thatsit"],
    ]

    /// Match only a complete recognition segment, accepting case,
    /// punctuation, width, diacritics, and apostrophe variants. This is safe
    /// for both full partials and finals because longer sentences never match.
    static func isStandaloneFinishPhrase(_ text: String) -> Bool {
        let tokens = normalizedTokens(in: text)
        return finishPhrases.contains(tokens)
    }

    /// Remove one marked trailing control phrase while preserving the command
    /// before it. Callers must decide that the phrase is control input first;
    /// this helper deliberately does not classify ordinary conversational use.
    static func strippingTrailingFinishPhrase(from text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?iu)(^|[\s,;:—–-]+)(?:thatsit|thats\s+it|that\s*['’‘ʼ＇]?\s*s\s+it|that\s+is\s+it)(?:[\s.!?,;:…'’‘ʼ＇\"()\[\]]*)$"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return value
        }
        return String(value[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ",;:—–-")
            ))
    }

    private static func normalizedTokens(
        in text: String
    ) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let apostropheNormalized = folded
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "‘", with: "")
            .replacingOccurrences(of: "ʼ", with: "")
            .replacingOccurrences(of: "＇", with: "")
        return apostropheNormalized.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Exactly-once control gate shared by partial and final recognition. A full
/// partial can win immediately; the later final then becomes a harmless no-op.
struct AdamFinishPhraseGate: Equatable, Sendable {
    private(set) var isConsumed = false

    mutating func consumeIfMatched(_ text: String) -> Bool {
        guard !isConsumed,
              AdamFinishPhrasePolicy.isStandaloneFinishPhrase(text) else {
            return false
        }
        isConsumed = true
        return true
    }

    mutating func reset() {
        isConsumed = false
    }
}

/// One-shot lifecycle for the conversational handoff cue. The session arms
/// this when successful playback begins, advances it only after capture has
/// been restored, and invalidates stale/cancelled turns by generation.
struct AdamReadyCueGate: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case idle
        case awaitingCapture(UInt64)
        case playing(UInt64)
    }

    private var generation: UInt64 = 0
    private var state: State = .idle

    var isBlockingCapture: Bool {
        if case .playing = state { return true }
        return false
    }

    mutating func arm() -> UInt64 {
        generation &+= 1
        state = .awaitingCapture(generation)
        return generation
    }

    mutating func beginIfCaptureReady(ticket: UInt64) -> Bool {
        guard state == .awaitingCapture(ticket), ticket == generation else {
            return false
        }
        state = .playing(ticket)
        return true
    }

    mutating func complete(ticket: UInt64) -> Bool {
        guard state == .playing(ticket), ticket == generation else {
            return false
        }
        state = .idle
        return true
    }

    mutating func cancel() {
        generation &+= 1
        state = .idle
    }
}
