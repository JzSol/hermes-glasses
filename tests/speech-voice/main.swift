// Standalone tests for the pure speech-voice policy. They never construct an
// AVSpeechSynthesisVoice; only Foundation descriptors are ranked.
// Build with:
//   xcrun swiftc \
//     HermesGlasses/Services/VoiceLocale.swift \
//     HermesGlasses/Services/HermesSpeechSynthesizer.swift \
//     tests/speech-voice/main.swift -o /tmp/speech-voice-tests && /tmp/speech-voice-tests

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

func voice(
    _ name: String,
    _ language: String,
    quality: Int,
    gender: HermesSpeechVoiceGender = .unspecified
) -> HermesSpeechVoiceDescriptor {
    HermesSpeechVoiceDescriptor(
        name: name,
        language: language,
        quality: quality,
        gender: gender
    )
}

// A British male wins even when a non-male British voice has a better quality
// tier. Gender is a higher-level preference than quality.
let malePriority = HermesSpeechVoicePolicy.select(
    for: .englishUS,
    voices: [
        voice("British Premium", "en-GB", quality: 3, gender: .female),
        voice("British Default", "en-GB", quality: 1, gender: .male),
        voice("US Premium", "en-US", quality: 3, gender: .male)
    ]
)
expect(malePriority?.descriptor.name == "British Default",
       "British male has priority over higher-quality British non-male")
expect(malePriority?.kind == .britishMale,
       "British male selection is classified correctly")
expect(malePriority?.britishVoiceNotice == nil,
       "British male selection needs no install warning")

// Quality decides within the British-male tier.
let qualityPriority = HermesSpeechVoicePolicy.select(
    for: .englishUS,
    voices: [
        voice("British Enhanced", "en-GB", quality: 2, gender: .male),
        voice("British Premium", "en-GB", quality: 3, gender: .male)
    ]
)
expect(qualityPriority?.descriptor.name == "British Premium",
       "British male quality tiers are ranked premium first")

// When no male British voice exists, the best exact en-GB voice is retained.
let britishFallback = HermesSpeechVoicePolicy.select(
    for: .englishUS,
    voices: [
        voice("British Enhanced", "en-GB", quality: 2, gender: .female),
        voice("British Premium", "en-GB", quality: 3, gender: .unspecified)
    ]
)
expect(britishFallback?.descriptor.name == "British Premium",
       "British fallback keeps the highest-quality exact en-GB voice")
expect(britishFallback?.kind == .britishFallback,
       "British fallback is classified correctly")
expect(britishFallback?.britishVoiceNotice?.contains("British male") == true,
       "British fallback explains how to install a male voice")

// An underscore and case variation still represent exact en-GB.
let normalizedBritish = HermesSpeechVoicePolicy.select(
    for: .englishUS,
    voices: [voice("British Male", "EN_gb", quality: 2, gender: .male)]
)
expect(normalizedBritish?.kind == .britishMale,
       "British locale matching normalizes case and separators")

// With no British voices, preserve en-US before considering another English
// region, even if the other region has a higher quality tier.
let englishFallback = HermesSpeechVoicePolicy.select(
    for: .englishUS,
    voices: [
        voice("Australian Premium", "en-AU", quality: 3),
        voice("US Enhanced", "en-US", quality: 2)
    ]
)
expect(englishFallback?.descriptor.name == "US Enhanced",
       "English fallback preserves the requested en-US locale")
expect(englishFallback?.kind == .sameLanguageFallback,
       "English fallback is classified correctly")
expect(englishFallback?.britishVoiceNotice?.contains("not installed") == true,
       "English fallback exposes a British install notice")

// Quality wins first and the localized name is the deterministic tie-break.
let tieBreak = HermesSpeechVoicePolicy.select(
    for: .englishUS,
    voices: [
        voice("Zed", "en-US", quality: 3),
        voice("Alice", "en-US", quality: 3)
    ]
)
expect(tieBreak?.descriptor.name == "Alice",
       "same-quality English voices use an ascending name tie-break")

// Latvian selection never crosses into English, and a regional Latvian voice
// remains acceptable when the exact lv-LV voice is not installed.
let latvian = HermesSpeechVoicePolicy.select(
    for: .latvianLV,
    voices: [
        voice("English Premium", "en-US", quality: 3),
        voice("Latvian Voice", "lv-LV", quality: 1)
    ]
)
expect(latvian?.descriptor.language == "lv-LV",
       "Latvian selection preserves the Latvian language")
expect(latvian?.britishVoiceNotice == nil,
       "Latvian selection has no British-English notice")

let regionalLatvian = HermesSpeechVoicePolicy.select(
    for: .latvianLV,
    voices: [voice("Latvian Regional", "lv", quality: 2)]
)
expect(regionalLatvian?.descriptor.name == "Latvian Regional",
       "Latvian same-language regional fallback is allowed")

let missingLatvian = HermesSpeechVoicePolicy.select(
    for: .latvianLV,
    voices: [voice("English Premium", "en-US", quality: 3)]
)
expect(missingLatvian == nil,
       "missing Latvian voice does not fall back across languages")

if failures > 0 {
    print("\(failures) test(s) FAILED")
    exit(1)
}
print("All speech voice tests passed")
