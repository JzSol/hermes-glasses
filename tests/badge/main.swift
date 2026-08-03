//
// Standalone tests for BadgeParser. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/EncounterEvent.swift \
//     HermesGlasses/Services/Providers/AIProvider.swift \
//     HermesGlasses/Services/Providers/AnthropicProvider.swift \
//     HermesGlasses/Services/Providers/OpenAICompatibleProvider.swift \
//     HermesGlasses/Services/Providers/GeminiProvider.swift \
//     HermesGlasses/Services/Social/BadgeParser.swift \
//     tests/badge/main.swift -o /tmp/badge-tests && /tmp/badge-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

// MARK: - The canonical badge

let canonical = BadgeParser.parse(
    ["Dr. Sarah Chen", "RADIOLOGY", "Auckland City Hospital"], source: .onDevice)
expectEqual(canonical?.name, "Sarah Chen", "honorific stripped from name")
expectEqual(canonical?.title, "Radiology", "shouting title is title-cased")
expectEqual(canonical?.org, "Auckland City Hospital", "org matched by keyword")
expectEqual(canonical?.source, .onDevice, "source recorded")
expectEqual(canonical?.rawLines,
            ["Dr. Sarah Chen", "RADIOLOGY", "Auckland City Hospital"],
            "raw lines kept verbatim")

// MARK: - Name only

let nameOnly = BadgeParser.parse(["Sarah Chen"], source: .onDevice)
expectEqual(nameOnly?.name, "Sarah Chen", "bare name parses")
expectEqual(nameOnly?.title, nil, "bare name has no title")
expectEqual(nameOnly?.org, nil, "bare name has no org")

// MARK: - ALL CAPS and honorifics

expectEqual(BadgeParser.parse(["SARAH CHEN"], source: .onDevice)?.name,
            "Sarah Chen", "shouting name is title-cased")
expectEqual(BadgeParser.parse(["Prof. Alan Turing"], source: .onDevice)?.name,
            "Alan Turing", "Prof. stripped")
expectEqual(BadgeParser.parse(["Mrs Ada Lovelace"], source: .onDevice)?.name,
            "Ada Lovelace", "honorific without a dot stripped")

// MARK: - One line left over is a title, not an org

let titled = BadgeParser.parse(["Sarah Chen", "Radiology"], source: .onDevice)
expectEqual(titled?.title, "Radiology", "single leftover line is the title")
expectEqual(titled?.org, nil, "single leftover line is not an org")

// MARK: - Two lines left over, no keyword: last one is the org

let guessed = BadgeParser.parse(
    ["Sarah Chen", "Radiology", "Level Three"], source: .onDevice)
expectEqual(guessed?.title, "Radiology", "first leftover is the title")
expectEqual(guessed?.org, "Level Three", "last leftover becomes the org")

// MARK: - Rejections

expectEqual(BadgeParser.parse([], source: .onDevice), nil, "no lines, no badge")
expectEqual(BadgeParser.parse(["!!", "  ", "*"], source: .onDevice), nil,
            "punctuation-only lines are not a badge")
expectEqual(BadgeParser.parse(["12345"], source: .onDevice), nil,
            "digits alone are not a badge")
expectEqual(BadgeParser.parse(["ACME LTD"], source: .onDevice), nil,
            "an org line alone is not a name")
expectEqual(BadgeParser.parse(["lower case words here"], source: .onDevice), nil,
            "uncapitalised text is not a name")
expectEqual(
    BadgeParser.parse(["Sarah Anne Marie Chen Smith"], source: .onDevice), nil,
    "five tokens is too many to be a name")

// A line with digits is skipped, and the next usable line becomes the name.
let afterRoom = BadgeParser.parse(["Room 402", "Sarah Chen"], source: .onDevice)
expectEqual(afterRoom?.name, "Sarah Chen", "digit line skipped when finding a name")
// Known quirk: a digit line that isn't the name doesn't get discarded - it's
// still eligible as the lone leftover line, so it becomes the title rather
// than being dropped. Documented here so a future change to this behaviour
// is a deliberate decision, not an accidental regression.
expectEqual(afterRoom?.title, "Room 402",
            "leftover digit line still ends up as the title (documented quirk)")

// An org-keyword line wins over the "last leftover" heuristic even when it
// isn't the last line.
let orgFirst = BadgeParser.parse(
    ["Sarah Chen", "Acme Hospital", "Radiology"], source: .onDevice)
expectEqual(orgFirst?.org, "Acme Hospital", "org keyword wins regardless of position")
expectEqual(orgFirst?.title, "Radiology", "remaining single line is still the title")

// MARK: - Assisted source is carried through

expectEqual(BadgeParser.parse(["Sarah Chen"], source: .assisted)?.source,
            .assisted, "assisted source recorded")

// MARK: - Whitespace

expectEqual(BadgeParser.parse(["   Sarah Chen   "], source: .onDevice)?.name,
            "Sarah Chen", "surrounding whitespace trimmed")

// MARK: - BadgeAssist reply parsing

expectEqual(BadgeAssist.parse("NONE"), nil, "NONE means no badge")
expectEqual(BadgeAssist.parse("  none  "), nil, "NONE is matched case- and space-insensitively")
expectEqual(BadgeAssist.parse(""), nil, "an empty reply is no badge")
expectEqual(BadgeAssist.parse("   \n  \n "), nil, "a whitespace reply is no badge")

let assisted = BadgeAssist.parse("Dr. Sarah Chen\nRADIOLOGY\nAuckland City Hospital")
expectEqual(assisted?.name, "Sarah Chen", "assisted reply parses a name")
expectEqual(assisted?.org, "Auckland City Hospital", "assisted reply parses an org")
expectEqual(assisted?.source, .assisted, "assisted replies are marked assisted")

expectEqual(BadgeAssist.parse("Sarah Chen\n\n   \nRadiology")?.title, "Radiology",
            "blank lines in the reply are dropped")
expectEqual(BadgeAssist.parse("I could not see a badge."), nil,
            "prose that is not a name yields no badge")

// MARK: - Which failures end the whole pass

expectTrue(BadgeAssist.isFatal(AIProviderError.missingKey), "a missing key is fatal")
expectTrue(BadgeAssist.isFatal(AIProviderError.invalidURL("nope")), "a bad URL is fatal")
expectTrue(BadgeAssist.isFatal(AIProviderError.http(status: 401, message: "x")),
           "401 is fatal")
expectTrue(BadgeAssist.isFatal(AIProviderError.http(status: 403, message: "x")),
           "403 is fatal")
expectTrue(!BadgeAssist.isFatal(AIProviderError.http(status: 500, message: "x")),
           "a server error is not fatal - the next photo may work")
expectTrue(!BadgeAssist.isFatal(AIProviderError.badResponse("garbled")),
           "one garbled response is not fatal")
expectTrue(!BadgeAssist.isFatal(URLError(.timedOut)), "a timeout is not fatal")

// MARK: - A reply is bounded before it reaches storage
//
// rawLines is persisted in encounters.json and rendered line-by-line, so a
// runaway or chatty reply must not decide how much gets written to disk.

let chatty = BadgeAssist.parse(
    (["Sarah Chen"] + (1...40).map { "Line \($0)" }).joined(separator: "\n"))
expectEqual(chatty?.name, "Sarah Chen", "a long reply still parses its name")
expectEqual(chatty?.rawLines.count, BadgeAssist.maxReplyLines,
            "a long reply is capped to maxReplyLines lines")
expectTrue(chatty!.rawLines.count <= 8, "the line cap is at most eight lines")

let longLine = String(repeating: "x", count: 500)
let runaway = BadgeAssist.parse("Sarah Chen\n\(longLine)")
expectEqual(runaway?.rawLines.count, 2, "a two-line reply keeps both lines")
expectEqual(runaway?.rawLines[1].count, BadgeAssist.maxLineLength,
            "an over-long line is truncated to maxLineLength")
expectTrue(runaway!.rawLines.allSatisfy { $0.count <= 120 },
           "no stored line exceeds 120 characters")

// A normal badge is untouched by either bound.
expectEqual(BadgeAssist.parse("Dr. Sarah Chen\nRADIOLOGY")?.rawLines,
            ["Dr. Sarah Chen", "RADIOLOGY"],
            "a short reply is stored verbatim")

// MARK: - Badge kind

expectEqual(Badge.Kind(detectorLabel: "conference_lanyard"), .conferenceLanyard,
            "detector label maps to a kind")
expectEqual(Badge.Kind(detectorLabel: "corporate_id"), .corporateID,
            "corporate_id maps to a kind")
expectEqual(Badge.Kind(detectorLabel: "clinical_id"), .clinicalID,
            "clinical_id maps to a kind")
expectEqual(Badge.Kind(detectorLabel: "handheld_id"), .handheldID,
            "handheld_id maps to a kind")
expectTrue(Badge.Kind(detectorLabel: "person") == nil,
           "an unknown label is not a badge kind")

// MARK: - Source precedence
//
// A decoded barcode is not a guess: it outranks OCR, and a hand
// correction still outranks everything.

expectTrue(Badge.Source.manual.rank > Badge.Source.barcode.rank,
           "manual outranks barcode")
expectTrue(Badge.Source.barcode.rank > Badge.Source.onDevice.rank,
           "barcode outranks on-device OCR")
expectTrue(Badge.Source.onDevice.rank > Badge.Source.assisted.rank,
           "on-device OCR outranks assist")

// MARK: - Decoding an encounters.json written before this change

let legacyJSON = """
{"rawLines":["Sarah Chen","RADIOLOGY"],"source":"onDevice","name":"Sarah Chen"}
""".data(using: .utf8)!
let legacy = try? JSONDecoder().decode(Badge.self, from: legacyJSON)
expectEqual(legacy?.name, "Sarah Chen", "a pre-change badge still decodes")
expectTrue(legacy?.kind == nil, "a pre-change badge has no kind")
expectTrue(legacy?.badgeRect == nil, "a pre-change badge has no rect")
expectTrue(legacy?.portraitFilename == nil, "a pre-change badge has no portrait")

// MARK: - preservingLocalFields
//
// Badge assist replies with TEXT ONLY. It never sees the detector's box,
// the badge kind or the portrait, so replacing a badge wholesale would
// silently drop the things only the on-device pass can know.

let onDeviceBadge = Badge(
    name: nil, rawLines: [], source: .onDevice,
    kind: .conferenceLanyard, barcodePayload: "ATT-4471",
    portraitFilename: "abc-portrait-0.jpg",
    badgeRect: CGRect(x: 0.3, y: 0.4, width: 0.2, height: 0.1)
)
let assistedBadge = Badge(
    name: "Sarah Chen", rawLines: ["Sarah Chen"], source: .assisted
)
let carried = assistedBadge.preservingLocalFields(from: onDeviceBadge)
expectEqual(carried.name, "Sarah Chen", "the assisted name wins")
expectEqual(carried.source, .assisted, "the assisted source is kept")
expectEqual(carried.kind, .conferenceLanyard, "the kind is carried forward")
expectEqual(carried.barcodePayload, "ATT-4471", "the payload is carried forward")
expectEqual(carried.portraitFilename, "abc-portrait-0.jpg",
            "the portrait is carried forward")
expectTrue(carried.badgeRect == onDeviceBadge.badgeRect, "the rect is carried forward")

// A newer value must never be clobbered by an older one.
let bothSet = Badge(
    name: "A", rawLines: [], source: .barcode, kind: .clinicalID
).preservingLocalFields(from: onDeviceBadge)
expectEqual(bothSet.kind, .clinicalID, "an existing kind is not overwritten")

// Nothing to carry from is a no-op, not a crash.
expectEqual(assistedBadge.preservingLocalFields(from: nil).name, "Sarah Chen",
            "preserving from nil returns self")

print(failures == 0 ? "\nAll badge tests passed" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
