// Standalone tests for AdamBuildMetadata. No XCTest target is required.
// Build + run:
//
//   swiftc HermesGlasses/Services/AdamBuildMetadata.swift \
//     tests/adam-build-metadata/main.swift -o /tmp/adam-build-metadata-tests && \
//     /tmp/adam-build-metadata-tests

import Foundation

var failures = 0

func expect(_ condition: Bool, _ label: String) {
    if condition { print("PASS \(label)") }
    else {
        failures += 1
        print("FAIL \(label)")
    }
}

let now = Date(timeIntervalSince1970: 2_000_000_000)
let locale = Locale(identifier: "en_US")
let calendar = Calendar(identifier: .gregorian)

let justUnder = AdamBuildMetadata.updateLabel(
    for: now.addingTimeInterval(-AdamBuildMetadata.relativeAgeThreshold + 1),
    now: now,
    locale: locale,
    calendar: calendar
)
let exact = AdamBuildMetadata.updateLabel(
    for: now.addingTimeInterval(-AdamBuildMetadata.relativeAgeThreshold),
    now: now,
    locale: locale,
    calendar: calendar
)
let justOver = AdamBuildMetadata.updateLabel(
    for: now.addingTimeInterval(-AdamBuildMetadata.relativeAgeThreshold - 1),
    now: now,
    locale: locale,
    calendar: calendar
)
let twoDays = AdamBuildMetadata.updateLabel(
    for: now.addingTimeInterval(-2 * 24 * 60 * 60 - 1),
    now: now,
    locale: locale,
    calendar: calendar
)

expect(justUnder.contains("Updated") && !justUnder.contains("ago"),
       "just below 24 hours uses local date/time")
expect(justUnder.range(of: "\\d{1,2}:\\d{2}:\\d{2}", options: .regularExpression) == nil,
       "fresh update omits seconds")
expect(!justUnder.contains("GMT") && !justUnder.contains("UTC"),
       "fresh update omits raw timezone")
expect(exact.contains("1 day ago"), "exactly 24 hours uses singular relative age")
expect(justOver.contains("1 day ago"), "just above 24 hours uses singular relative age")
expect(twoDays.contains("2 days ago"), "multi-day age uses plural relative age")
expect(AdamBuildMetadata.updateLabel(
    for: nil,
    now: now,
    locale: locale,
    calendar: calendar
) == "Update date unavailable", "missing timestamp is safe")
expect(AdamBuildMetadata.updateLabel(
    for: now.addingTimeInterval(1),
    now: now,
    locale: locale,
    calendar: calendar
) == "Update date unavailable", "future timestamp is safe")
let invalid = Date(timeIntervalSinceReferenceDate: .nan)
expect(AdamBuildMetadata.updateLabel(
    for: invalid,
    now: now,
    locale: locale,
    calendar: calendar
) == "Update date unavailable", "invalid timestamp is safe")

exit(failures == 0 ? 0 : 1)
