//
// WakeWordGate.swift
//
// Pure state machine for the always-armed voice loop. It intentionally does
// not own a timer, recognizer, audio session, or UI callback: callers pass the
// current time and drive timeout() from their own lifecycle.
//

import Foundation

/// Whether a finalized or partial transcript should reach the agent.
struct WakeWordGate: Sendable {
    static let defaultCommandWindow: TimeInterval = 8
    static let defaultFollowUpWindow: TimeInterval = 30

    enum State: Equatable, Sendable {
        case armed
        case awaitingCommand(until: Date)
        case speaking

        var isAwaitingCommand: Bool {
            if case .awaitingCommand = self { return true }
            return false
        }
    }

    enum Action: Equatable, Sendable {
        /// The transcript is ambient speech and must not be submitted.
        case suppressed
        /// A wake phrase was heard by itself; play an earcon/TTS prompt and
        /// collect the next finalized utterance.
        case prompt
        /// A command is ready to send to Hermes. The wake phrase is removed.
        case submit(String)
        /// A wake phrase interrupted an active reply; collect the next final.
        case interrupt
        /// A wake phrase with a command interrupted an active reply.
        case interruptAndSubmit(String)
        /// The command window expired before a command arrived.
        case rearmed
        /// Speech is in a continuous follow-up window; keep listening and
        /// extend the deadline while the wearer is still talking.
        case extended
    }

    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    private(set) var state: State = .armed
    /// Whether the current command window was opened automatically after a
    /// response. Kept separate from `State` so the existing state shape stays
    /// small and callers can still compare its timing in pure tests.
    private(set) var isFollowUpWindow = false
    private let commandWindow: TimeInterval
    private let followUpWindow: TimeInterval
    private let aliases: [[String]]

    /// Create a gate with the single Adam wake word. Custom aliases are
    /// available for tests and future personas, but every alias is still
    /// matched by whole tokens at the beginning of an utterance.
    init(
        commandWindow: TimeInterval = WakeWordGate.defaultCommandWindow,
        followUpWindow: TimeInterval = WakeWordGate.defaultFollowUpWindow,
        aliases: [String] = ["Adam"]
    ) {
        self.commandWindow = max(0, commandWindow)
        self.followUpWindow = max(0, followUpWindow)
        self.aliases = aliases.compactMap { Self.tokenValues(in: $0) }
            .filter { !$0.isEmpty }
    }

    /// The deadline of the active command window, if any. Session timers use
    /// this instead of assuming every window has the initial wake duration.
    var commandDeadline: Date? {
        guard case .awaitingCommand(let deadline) = state else { return nil }
        return deadline
    }

    /// Open the post-response follow-up window. A caller should invoke this
    /// only after local/bridge TTS has finished and recognition has had its
    /// resume grace period.
    @discardableResult
    mutating func openFollowUpWindow(now: Date = Date()) -> Bool {
        guard case .armed = state else { return false }
        state = .awaitingCommand(until: now.addingTimeInterval(followUpWindow))
        isFollowUpWindow = true
        return true
    }

    /// Extend an active follow-up while a partial transcript is changing.
    @discardableResult
    mutating func extendFollowUpWindow(now: Date = Date()) -> Bool {
        guard isFollowUpWindow,
              case .awaitingCommand = state else { return false }
        state = .awaitingCommand(until: now.addingTimeInterval(followUpWindow))
        return true
    }

    /// Seconds remaining in the active command window.
    func remainingCommandWindow(now: Date = Date()) -> TimeInterval? {
        guard let commandDeadline else { return nil }
        return max(0, commandDeadline.timeIntervalSince(now))
    }

    /// Handle one final transcript. In armed mode only an alias at the
    /// beginning of the utterance is meaningful. In awaiting mode the next
    /// non-empty final is always the command, as promised by the wake UX.
    mutating func handleFinal(_ text: String, now: Date = Date()) -> Action {
        if case .awaitingCommand(let deadline) = state, now >= deadline {
            state = .armed
            isFollowUpWindow = false
            return .suppressed
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .suppressed }

        switch state {
        case .awaitingCommand:
            state = .armed
            isFollowUpWindow = false
            return .submit(trimmed)
        case .speaking:
            guard let match = prefixMatch(in: text) else { return .suppressed }
            if let tail = match.tail, !tail.isEmpty {
                state = .armed
                isFollowUpWindow = false
                return .interruptAndSubmit(tail)
            }
            state = .awaitingCommand(until: now.addingTimeInterval(commandWindow))
            isFollowUpWindow = false
            return .interrupt
        case .armed:
            guard let match = prefixMatch(in: text) else { return .suppressed }
            if let tail = match.tail, !tail.isEmpty {
                state = .armed
                isFollowUpWindow = false
                return .submit(tail)
            }
            state = .awaitingCommand(until: now.addingTimeInterval(commandWindow))
            isFollowUpWindow = false
            return .prompt
        }
    }

    /// Partial transcripts are deliberately hidden while armed. While a
    /// reply is speaking, a completed wake prefix can still tell the caller
    /// to stop TTS early; the final handler will decide whether a command tail
    /// exists. This keeps ambient partials private and avoids substring wake
    /// matches.
    mutating func handlePartial(_ text: String, now: Date = Date()) -> Action {
        if case .awaitingCommand(let deadline) = state, now >= deadline {
            state = .armed
            isFollowUpWindow = false
            return .rearmed
        }
        if isFollowUpWindow,
           case .awaitingCommand = state,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           extendFollowUpWindow(now: now) {
            return .extended
        }
        guard case .speaking = state, prefixMatch(in: text) != nil else {
            return .suppressed
        }
        return .interrupt
    }

    /// Let the gate know that local TTS is speaking. A later wake can then
    /// produce `.interrupt` for the view model to stop the synthesizer.
    mutating func setSpeaking(_ speaking: Bool) {
        state = speaking ? .speaking : .armed
        isFollowUpWindow = false
    }

    /// Re-arm after a user cancellation, a completed command, or an agent
    /// failure. Returning an action makes lifecycle transitions easy to test.
    mutating func cancel() -> Action {
        state = .armed
        isFollowUpWindow = false
        return .rearmed
    }

    mutating func completed() -> Action {
        state = .armed
        isFollowUpWindow = false
        return .rearmed
    }

    mutating func failed() -> Action {
        state = .armed
        isFollowUpWindow = false
        return .rearmed
    }

    /// Expire the command window without consuming a future utterance.
    @discardableResult
    mutating func timeout(now: Date = Date()) -> Bool {
        guard case .awaitingCommand(let deadline) = state, now >= deadline else {
            return false
        }
        state = .armed
        isFollowUpWindow = false
        return true
    }

    private struct PrefixMatch {
        let tail: String?
    }

    private func prefixMatch(in text: String) -> PrefixMatch? {
        let words = Self.tokens(in: text)
        guard !words.isEmpty else { return nil }

        for alias in aliases {
            guard words.count >= alias.count else { continue }
            let matches = zip(alias, words).allSatisfy { $0 == $1.normalized }
            guard matches else { continue }

            let end = words[alias.count - 1].range.upperBound
            let rawTail = String(text[end...])
            let tail = Self.trimLeadingSeparators(rawTail)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PrefixMatch(tail: tail.isEmpty ? nil : tail)
        }
        return nil
    }

    private static func tokenValues(in text: String) -> [String]? {
        let values = tokens(in: text).map(\.normalized)
        return values.isEmpty ? nil : values
    }

    /// Tokenize on every non-letter/non-number character. This makes
    /// "Adam!" and "Adam—" equivalent while ensuring "they adamant" is
    /// never treated as a wake phrase.
    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?

        func finish(_ end: String.Index, into result: inout [Token]) {
            guard let start else { return }
            let raw = String(text[start..<end])
            result.append(Token(normalized: normalize(raw), range: start..<end))
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else if start != nil {
                finish(index, into: &result)
                start = nil
            }
            index = text.index(after: index)
        }
        finish(text.endIndex, into: &result)
        return result
    }

    private static func normalize(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func trimLeadingSeparators(_ text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isWhitespace || character.isPunctuation || character.isSymbol else {
                break
            }
            index = text.index(after: index)
        }
        return String(text[index...])
    }
}
