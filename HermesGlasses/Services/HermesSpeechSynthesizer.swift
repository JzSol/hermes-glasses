//
// HermesSpeechSynthesizer.swift
//
// On-device text-to-speech for Hermes's replies via AVSpeechSynthesizer.
// Replaces bridge-side TTS: speech starts the instant the response text
// arrives, no cloud synthesis or PCM streaming. Plays through the current
// audio route (glasses in HFP mode). Interruption is stopSpeaking().
//

import AVFoundation
import Foundation
import os

/// The small, Foundation-only description used to choose an installed speech
/// voice. Keeping this separate from AVSpeechSynthesisVoice makes the policy
/// deterministic and testable without constructing framework voice objects.
enum HermesSpeechVoiceGender: String, Codable, Equatable, Sendable {
    case male
    case female
    case unspecified

    var label: String {
        switch self {
        case .male:
            return "Male"
        case .female:
            return "Female"
        case .unspecified:
            return "Unspecified"
        }
    }
}

struct HermesSpeechVoiceDescriptor: Codable, Equatable, Sendable {
    let name: String
    let language: String
    let quality: Int
    let gender: HermesSpeechVoiceGender

    var normalizedLanguage: String {
        language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    var baseLanguage: String {
        normalizedLanguage.split(separator: "-").first.map(String.init)
            ?? normalizedLanguage
    }
}

enum HermesSpeechVoiceSelectionKind: String, Codable, Equatable, Sendable {
    case britishMale
    case britishFallback
    case sameLanguageFallback
    case locale
}

struct HermesSpeechVoiceSelection: Codable, Equatable, Sendable {
    let descriptor: HermesSpeechVoiceDescriptor
    let kind: HermesSpeechVoiceSelectionKind

    var isBritish: Bool {
        descriptor.normalizedLanguage == "en-gb"
    }

    /// A concise status message suitable for the Adam setup/status card.
    /// Latvian callers intentionally receive no British-English notice.
    var britishVoiceNotice: String? {
        switch kind {
        case .britishMale, .locale:
            return nil
        case .britishFallback:
            return "Adam is using British English (\(descriptor.name)). For a British male voice, install one in Settings → Accessibility → Spoken Content → Voices."
        case .sameLanguageFallback:
            return "A British English voice is not installed. Adam is using \(descriptor.name). Install an English (United Kingdom) voice in Settings → Accessibility → Spoken Content → Voices."
        }
    }
}

/// Voice-selection policy shared by the iPhone synthesizer and its standalone
/// tests. English intentionally prefers British voices even though the speech
/// recognizer/bridge locale remains `en-US`.
enum HermesSpeechVoicePolicy {
    static func select(
        for locale: VoiceLocale,
        voices: [HermesSpeechVoiceDescriptor]
    ) -> HermesSpeechVoiceSelection? {
        let target = normalized(locale.rawValue)
        let languageVoices = voices.filter { $0.baseLanguage == baseLanguage(of: target) }
        guard !languageVoices.isEmpty else { return nil }

        switch locale {
        case .englishUS:
            let british = languageVoices.filter { $0.normalizedLanguage == "en-gb" }
            if let male = best(british.filter { $0.gender == .male }) {
                return HermesSpeechVoiceSelection(
                    descriptor: male,
                    kind: .britishMale
                )
            }
            if let britishVoice = best(british) {
                return HermesSpeechVoiceSelection(
                    descriptor: britishVoice,
                    kind: .britishFallback
                )
            }

            // Preserve the requested locale when British English is not
            // installed, then use another English region as a last resort.
            let exact = languageVoices.filter { $0.normalizedLanguage == target }
            let fallback = best(exact.isEmpty ? languageVoices : exact)
            guard let fallback else { return nil }
            return HermesSpeechVoiceSelection(
                descriptor: fallback,
                kind: .sameLanguageFallback
            )

        case .latvianLV:
            // Never use an English (or any other language) voice for a
            // Latvian selection. A regional Latvian voice is still valid if
            // the exact lv-LV voice is unavailable.
            let exact = languageVoices.filter { $0.normalizedLanguage == target }
            let candidates = exact.isEmpty ? languageVoices : exact
            guard let latvian = best(candidates) else { return nil }
            return HermesSpeechVoiceSelection(
                descriptor: latvian,
                kind: exact.isEmpty ? .sameLanguageFallback : .locale
            )
        }
    }

    private static func normalized(_ language: String) -> String {
        language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func baseLanguage(of language: String) -> String {
        normalized(language).split(separator: "-").first.map(String.init)
            ?? normalized(language)
    }

    /// Quality is the primary choice within a tier. Names provide a stable
    /// result when two installed voices have the same quality.
    private static func best(
        _ voices: [HermesSpeechVoiceDescriptor]
    ) -> HermesSpeechVoiceDescriptor? {
        voices.sorted { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality > rhs.quality
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.normalizedLanguage < rhs.normalizedLanguage
        }.first
    }
}

enum HermesSpeechSynthesisError: LocalizedError, Equatable, Sendable {
    case unsupportedVoice(locale: VoiceLocale)

    var errorDescription: String? {
        switch self {
        case .unsupportedVoice(let locale):
            return "No installed speech voice supports \(locale.label). Download a \(locale.label) voice in Settings → Accessibility → Spoken Content → Voices."
        }
    }
}

final class HermesSpeechSynthesizer: NSObject, @unchecked Sendable {
    // MARK: - Callbacks (delivered on the main queue)

    /// Fired when an utterance finishes OR is cancelled
    var onFinished: (() -> Void)?
    /// Fired when the selected locale has no installed voice or another
    /// speak-time capability problem prevents playback.
    var onError: ((String) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "tts")
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var locale: VoiceLocale
    private var voice: AVSpeechSynthesisVoice?
    private var voiceSelection: HermesSpeechVoiceSelection?
    private(set) var lastError: HermesSpeechSynthesisError?

    init(locale: VoiceLocale = .englishUS) {
        self.locale = locale
        let resolution = Self.resolveVoice(for: locale)
        self.voice = resolution?.voice
        self.voiceSelection = resolution?.selection
        self.lastError = self.voice == nil
            ? .unsupportedVoice(locale: locale)
            : nil

        super.init()
        synthesizer.delegate = self
        if let voice, let selection = voiceSelection {
            logger.info("TTS voice: \(voice.name, privacy: .public) (locale \(voice.language, privacy: .public), quality \(voice.quality.rawValue), selection \(selection.kind.rawValue, privacy: .public))")
        } else {
            logger.error("No installed TTS voice for locale \(locale.rawValue, privacy: .public)")
        }
    }

    // MARK: - Public API

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Whether an installed voice can speak the selected locale. A locale is
    /// not silently downgraded to English: callers can show this status and
    /// let the wearer download the requested voice.
    var isVoiceSupported: Bool { voice != nil }

    /// The installed voice currently used for replies.
    var voiceName: String? { voice?.name }

    var voiceLanguage: String? { voice?.language }

    /// A user-facing gender label for the selected installed voice.
    var voiceGender: String? { voiceSelection?.descriptor.gender.label }

    /// AVSpeechSynthesisVoice quality (default = 1, enhanced = 2,
    /// premium = 3), exposed for diagnostics without leaking AVFoundation
    /// types into the setup/status UI.
    var voiceQuality: Int? { voiceSelection?.descriptor.quality }

    /// British-English guidance for the English voice picker. Latvian keeps
    /// its locale-only behavior and intentionally has no British notice.
    var britishVoiceNotice: String? {
        guard locale == .englishUS else { return nil }
        return voiceSelection?.britishVoiceNotice
    }

    /// Alias kept concise for views that render a generic voice status row.
    var voiceNotice: String? { britishVoiceNotice }

    /// Select a different installed voice. The locale-bound voice is changed
    /// only after selection succeeds, so a failed Latvian switch cannot leave
    /// a currently speaking English session half-configured.
    @discardableResult
    func setLocale(_ newLocale: VoiceLocale) throws -> Bool {
        guard let resolution = Self.resolveVoice(for: newLocale) else {
            let error = HermesSpeechSynthesisError.unsupportedVoice(locale: newLocale)
            lastError = error
            throw error
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        locale = newLocale
        voice = resolution.voice
        voiceSelection = resolution.selection
        lastError = nil
        logger.info("TTS voice: \(resolution.voice.name, privacy: .public) (locale \(newLocale.rawValue, privacy: .public), quality \(resolution.voice.quality.rawValue), selection \(resolution.selection.kind.rawValue, privacy: .public))")
        return true
    }

    func changeLocale(to newLocale: VoiceLocale) throws {
        try setLocale(newLocale)
    }

    /// Speak on-device. Returning a boolean keeps existing call sites source
    /// compatible while giving new callers a synchronous capability result;
    /// onError also reports the localized reason on the main queue.
    @discardableResult
    func speak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            return true
        }
        guard let voice else {
            let error = lastError ?? .unsupportedVoice(locale: locale)
            let message = error.localizedDescription
            logger.error("TTS unavailable (locale \(self.locale.rawValue, privacy: .public))")
            DispatchQueue.main.async { [weak self] in
                self?.onError?(message)
                self?.onFinished?()
            }
            return false
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        if locale == .englishUS {
            // A slightly slower, subtly lowered delivery keeps the selected
            // British voice calm and intelligible through Ray-Ban HFP.
            utterance.rate = 0.44
            utterance.pitchMultiplier = 0.92
        }
        logger.info("Speaking \(trimmed.count) chars on-device")
        synthesizer.speak(utterance)
        return true
    }

    /// Barge-in: stop immediately. The delegate's didCancel fires onFinished.
    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private struct VoiceResolution {
        let voice: AVSpeechSynthesisVoice
        let selection: HermesSpeechVoiceSelection
    }

    private static func resolveVoice(for locale: VoiceLocale) -> VoiceResolution? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let described = installed.map(descriptor(for:))
        guard let selection = HermesSpeechVoicePolicy.select(
            for: locale,
            voices: described
        ) else {
            return nil
        }

        // Descriptors deliberately contain all ranking fields. Matching on
        // the complete value is sufficient even if iOS exposes two voices
        // with the same metadata; either produces the same policy result.
        guard let index = described.firstIndex(of: selection.descriptor) else {
            return nil
        }
        return VoiceResolution(voice: installed[index], selection: selection)
    }

    private static func descriptor(
        for voice: AVSpeechSynthesisVoice
    ) -> HermesSpeechVoiceDescriptor {
        let gender: HermesSpeechVoiceGender
        switch voice.gender {
        case .male:
            gender = .male
        case .female:
            gender = .female
        default:
            gender = .unspecified
        }
        return HermesSpeechVoiceDescriptor(
            name: voice.name,
            language: voice.language,
            quality: voice.quality.rawValue,
            gender: gender
        )
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension HermesSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }
}
