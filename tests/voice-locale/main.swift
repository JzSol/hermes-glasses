// Standalone tests for VoiceLocale. Build with:
//   xcrun swiftc HermesGlasses/Services/VoiceLocale.swift \
//     tests/voice-locale/main.swift -o /tmp/voice-locale-tests && /tmp/voice-locale-tests

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

expect(VoiceLocale.allCases.map(\.rawValue) == ["en-GB", "lv-LV"],
       "supported locale identifiers are stable")
expect(VoiceLocale.englishGB.label == "English (UK)", "English label")
expect(VoiceLocale.latvianLV.label == "Latvian", "Latvian label")
expect(VoiceLocale(identifier: "en_US") == .englishGB,
       "legacy US identifier migrates to British English")
expect(VoiceLocale(identifier: "en-GB") == .englishGB,
       "British English identifier parses")
expect(VoiceLocale(identifier: "LV-lv") == .latvianLV,
       "identifier matching is case insensitive")
expect(VoiceLocale(identifier: "de-DE") == nil,
       "unsupported locale is rejected")
expect(VoiceLocale.englishGB.replyLanguageDirective.localizedCaseInsensitiveContains("English"),
       "English reply directive names English")
expect(VoiceLocale.latvianLV.replyLanguageDirective.localizedCaseInsensitiveContains("latviešu"),
       "Latvian reply directive names Latvian")
expect(VoiceLocale.englishGB.speechLocale.identifier == "en-GB",
       "British English speech locale")
expect(VoiceLocale.latvianLV.speechLocale.identifier == "lv-LV",
       "Latvian speech locale")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
