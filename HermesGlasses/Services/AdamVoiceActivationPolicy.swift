//
// AdamVoiceActivationPolicy.swift
//
// Foundation-only activation policy for the reversible manual-listening test
// mode. The live session owns audio; this file keeps defaults and duplicate
// start/re-enable rules independently testable.
//

import Foundation

enum AdamVoiceActivationMode: String, Equatable, Sendable {
    case manual
    case wakeWord
}

enum AdamVoiceActivationPolicy {
    /// Manual is the testing-build default. A previously stored choice wins.
    static func mode(storedWakeWordEnabled: Bool?) -> AdamVoiceActivationMode {
        storedWakeWordEnabled == true ? .wakeWord : .manual
    }

    static func controlState(
        isStarting: Bool,
        isListening: Bool,
        isVoiceWindow: Bool
    ) -> AdamManualListeningControlState {
        if isStarting { return .starting }
        if isListening { return isVoiceWindow ? .listening : .working }
        return .ready
    }

    static func shouldRunCapture(
        mode: AdamVoiceActivationMode,
        manualListeningActive: Bool
    ) -> Bool {
        mode == .wakeWord || manualListeningActive
    }
}

enum AdamManualListeningControlState: Equatable, Sendable {
    case ready
    case starting
    case listening
    case working

    var title: String {
        switch self {
        case .ready: return "Start listening"
        case .starting: return "Starting microphone…"
        case .listening: return "Listening…"
        case .working: return "Adam is working…"
        }
    }
}

struct AdamManualListeningGate: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case starting(UInt64)
        case listening(UInt64)
    }

    private(set) var state: State = .idle
    private var generation: UInt64 = 0

    var isIdle: Bool { state == .idle }
    var isStarting: Bool {
        if case .starting = state { return true }
        return false
    }
    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    mutating func begin() -> UInt64? {
        guard isIdle else { return nil }
        generation &+= 1
        state = .starting(generation)
        return generation
    }

    mutating func markListening(ticket: UInt64) -> Bool {
        guard state == .starting(ticket), ticket == generation else {
            return false
        }
        state = .listening(ticket)
        return true
    }

    mutating func stop() {
        generation &+= 1
        state = .idle
    }
}
