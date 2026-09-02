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
        ["that", "is", "it"],
    ]

    /// Match only a complete final segment, accepting case, punctuation,
    /// width, diacritics, and straight/curly apostrophe variants.
    static func isStandaloneFinishPhrase(_ text: String) -> Bool {
        let tokens = normalizedTokens(in: text).map(String.init).map { token in
            token
                .replacingOccurrences(of: "'", with: "")
        }
        return finishPhrases.contains(tokens)
    }

    private static func normalizedTokens(
        in text: String
    ) -> [Substring] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let apostropheNormalized = folded
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
            .replacingOccurrences(of: "＇", with: "'")
        return apostropheNormalized.split {
            !$0.isLetter && !$0.isNumber && $0 != "'"
        }
    }
}
