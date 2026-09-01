//
// VoiceLocale.swift
//
// The two speech languages supported by the voice-only Adam prototype. Keep
// this type small and Foundation-only so its normalization and prompt
// contract can be tested without an iOS target.
//

import Foundation

/// A supported recognition and reply language.
enum VoiceLocale: String, CaseIterable, Codable, Sendable {
    case englishUS = "en-US"
    case latvianLV = "lv-LV"

    /// Short name suitable for a language picker.
    var label: String {
        switch self {
        case .englishUS:
            return "English (US)"
        case .latvianLV:
            return "Latvian"
        }
    }

    /// Alias for views that use the longer SwiftUI naming convention.
    var displayName: String { label }

    /// Stable identifier alias for settings and bridge adapters.
    var identifier: String { rawValue }

    /// The locale consumed by Speech and AVSpeechSynthesizer.
    var speechLocale: Locale { Locale(identifier: rawValue) }

    /// A stable language tag for JSON payloads and logs that do not contain
    /// user speech.
    var languageTag: String { rawValue }

    /// A compact instruction appended to an agent request so Hermes replies
    /// in the language chosen by the wearer.
    var replyLanguageDirective: String {
        switch self {
        case .englishUS:
            return "Reply in English (US)."
        case .latvianLV:
            return "Atbildi latviešu valodā."
        }
    }

    /// Short alias for prompt-building code.
    var replyDirective: String { replyLanguageDirective }

    /// The single wake word supplied to Apple's contextual recognizer. Wake
    /// matching itself lives in WakeWordGate, where token boundaries are
    /// enforced.
    var contextualWakePhrases: [String] {
        ["Adam"]
    }

    /// Parse the identifiers that can come from settings, JSON, or Locale.
    /// Apple commonly returns underscores for language/region separators, so
    /// accept those without broadening the supported language set.
    init?(identifier: String) {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        switch normalized {
        case "en-us":
            self = .englishUS
        case "lv-lv":
            self = .latvianLV
        default:
            return nil
        }
    }
}
