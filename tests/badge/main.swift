//
// Standalone tests for BadgeParser. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/EncounterEvent.swift \
//     HermesGlasses/Services/Providers/AIProvider.swift \
//     HermesGlasses/Services/Providers/AnthropicProvider.swift \
//     HermesGlasses/Services/Providers/OpenAICompatibleProvider.swift \
//     HermesGlasses/Services/Providers/GeminiProvider.swift \
//     HermesGlasses/Services/Social/BadgeParser.swift \
//     HermesGlasses/Services/Social/BarcodeReader.swift \
//     tests/badge/main.swift -o /tmp/badge-tests && /tmp/badge-tests
//
import CoreGraphics
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

// MARK: - Barcode payloads
//
// A conference QR usually carries a vCard. Unlike OCR this does not
// guess - so it lands at .barcode rank and outranks the text pass.

let vcard = """
BEGIN:VCARD
VERSION:3.0
FN:Sarah Chen
TITLE:Radiologist
ORG:Auckland City Hospital
END:VCARD
"""
let fromVCard = BarcodeReader.parse(vcard)
expectEqual(fromVCard?.name, "Sarah Chen", "vCard FN becomes the name")
expectEqual(fromVCard?.title, "Radiologist", "vCard TITLE becomes the title")
expectEqual(fromVCard?.org, "Auckland City Hospital", "vCard ORG becomes the org")
expectEqual(fromVCard?.source, .barcode, "a decoded vCard is barcode-sourced")
expectEqual(fromVCard?.barcodePayload, vcard, "the raw payload is kept")

// Folded lines are legal vCard and common in QR encoders.
let folded = "BEGIN:VCARD\r\nFN:Sarah Chen\r\nORG:Auckland City Hospital\r\nEND:VCARD"
expectEqual(BarcodeReader.parse(folded)?.name, "Sarah Chen",
            "CRLF line endings parse")

// Property parameters are legal too: FN;CHARSET=UTF-8:Sarah Chen
expectEqual(BarcodeReader.parse("BEGIN:VCARD\nFN;CHARSET=UTF-8:Sarah Chen\nEND:VCARD")?.name,
            "Sarah Chen", "a parameterised FN parses")

// vCard escapes commas and semicolons in values.
expectEqual(BarcodeReader.parse("BEGIN:VCARD\nFN:Chen\\, Sarah\nEND:VCARD")?.name,
            "Chen, Sarah", "escaped punctuation is unescaped")

// MECARD, the other common encoding.
let mecard = "MECARD:N:Chen,Sarah;ORG:Auckland City Hospital;;"
expectEqual(BarcodeReader.parse(mecard)?.name, "Sarah Chen",
            "MECARD N: last,first becomes first last")
expectEqual(BarcodeReader.parse(mecard)?.org, "Auckland City Hospital",
            "MECARD ORG parses")

// An opaque attendee id names nobody - but it is still what the tag says,
// so it is kept rather than thrown away.
let opaque = BarcodeReader.parse("ATT-4471")
expectTrue(opaque?.name == nil, "an opaque id is not a name")
expectEqual(opaque?.barcodePayload, "ATT-4471", "an opaque id is still kept")
expectEqual(opaque?.source, .barcode, "an opaque id is barcode-sourced")

// A URL is the same case.
expectTrue(BarcodeReader.parse("https://conf.example/a/4471")?.name == nil,
           "a URL is not a name")

// Nothing in, nothing out.
expectTrue(BarcodeReader.parse("")  == nil, "an empty payload yields no badge")
expectTrue(BarcodeReader.parse("   \n  ") == nil,
           "a whitespace payload yields no badge")

// A vCard with no FN is not a person.
expectTrue(BarcodeReader.parse("BEGIN:VCARD\nORG:Acme Ltd\nEND:VCARD")?.name == nil,
           "a vCard without FN names nobody")

// Bounded, for the same reason BadgeAssist is: rawLines is persisted and
// rendered, and a QR can carry kilobytes.
let longPayload = String(repeating: "A", count: 5000)
expectTrue((BarcodeReader.parse(longPayload)?.barcodePayload?.count ?? 0)
             <= BarcodeReader.maxPayloadLength,
           "an over-long payload is truncated")

// MARK: - Escaped delimiters vs. structural ones
//
// A structured value (vCard ORG, a MECARD field) uses the SAME character
// for its structural separator and its escape-protected literal. Splitting
// must happen on the raw text, before unescaping - unescaping first would
// turn an escaped delimiter into a real one and shear the value at the
// exact point the escape was protecting.

let escapedOrg = BarcodeReader.parse(
    "BEGIN:VCARD\nFN:Sarah Chen\nORG:Doctors\\; Associates\nEND:VCARD")
expectEqual(escapedOrg?.org, "Doctors; Associates",
            "an escaped semicolon in ORG is not treated as a field separator")

let structuredOrg = BarcodeReader.parse(
    "BEGIN:VCARD\nFN:Sarah Chen\nORG:Auckland City Hospital;Radiology\nEND:VCARD")
expectEqual(structuredOrg?.org, "Auckland City Hospital",
            "an unescaped semicolon in ORG is still a structural separator")

let mecardEscaped = BarcodeReader.parse(
    "MECARD:N:Chen,Sarah;ORG:Doctors\\; Associates;;")
expectEqual(mecardEscaped?.name, "Sarah Chen", "the rest of the MECARD still parses")
expectEqual(mecardEscaped?.org, "Doctors; Associates",
            "an escaped semicolon inside a MECARD field survives, not sheared into two fields")

// MARK: - Escape ordering: \\n is not \n
//
// A single left-to-right pass is required: reading "\n" as "space" before
// reading "\\" as "backslash" would misinterpret an escaped backslash
// followed by a literal "n" as an escaped newline.

expectEqual(BarcodeReader.parse("BEGIN:VCARD\nFN:X\\\\nY\nEND:VCARD")?.name,
            "X\\nY",
            "an escaped backslash followed by a literal n is not an escaped newline")
expectEqual(BarcodeReader.parse("BEGIN:VCARD\nFN:X\\nY\nEND:VCARD")?.name,
            "X Y", "an escaped newline still becomes a space")

// MARK: - Preferring a named badge over an opaque one
//
// A badge can carry two barcodes at once (a QR vCard next to a Code128
// check-in id). Vision does not guarantee observation order, so `read`
// must not just take the first parseable one. `preferred` is the pure
// helper it uses; a CGImage carrying two real barcodes isn't practical to
// construct in this standalone swiftc suite, so the helper is exercised
// directly instead of `read` itself.

let namedCandidate = BarcodeReader.parse(vcard)!
let opaqueCandidate = BarcodeReader.parse("ATT-4471")!
let urlCandidate = BarcodeReader.parse("https://conf.example/a/4471")!

expectEqual(BarcodeReader.preferred([opaqueCandidate, namedCandidate])?.name,
            "Sarah Chen", "a named badge is preferred over an opaque id")
expectEqual(BarcodeReader.preferred([namedCandidate, opaqueCandidate])?.name,
            "Sarah Chen", "order does not matter when one candidate has a name")
expectEqual(BarcodeReader.preferred([opaqueCandidate, urlCandidate])?.barcodePayload,
            "ATT-4471", "with no named candidate, the first parseable badge wins")
expectTrue(BarcodeReader.preferred([]) == nil, "no candidates yields no badge")

// MARK: - BadgeParser.merge - the detected-badge orchestration

// Extracted out of BadgeReader.readDetected so this branching - the one
// place a silent error puts a wrong name on a stranger's face - is
// reachable from this standalone suite. BadgeReader.swift itself imports
// UIKit and cannot compile here.

let rect1 = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
let rect2 = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4)
let rect3 = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.4)
let rect4 = CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.4)
let rect5 = CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.4)
let rect6 = CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.4)

// 1. Barcode named + OCR parsed: the barcode's name and .barcode source
// win; title/org fall back to OCR only where the barcode itself lacks
// them; rawLines are the OCR lines (OCR read something, so its lines beat
// the barcode's own single-line payload).
let nameOnlyBarcode = BarcodeReader.parse("MECARD:N:Chen,Sarah;;")!
expectTrue(nameOnlyBarcode.title == nil && nameOnlyBarcode.org == nil,
           "fixture: a bare MECARD name has no title or org")
let ocrLines1 = ["Sarah Chen", "Radiology", "Auckland City Hospital"]
let merged1 = BadgeParser.merge(
    barcode: nameOnlyBarcode, lines: ocrLines1, kind: .conferenceLanyard, rect: rect1)
expectEqual(merged1.name, "Sarah Chen", "1: barcode's name wins")
expectEqual(merged1.source, .barcode, "1: barcode source wins")
expectEqual(merged1.title, "Radiology", "1: title falls back to OCR")
expectEqual(merged1.org, "Auckland City Hospital", "1: org falls back to OCR")
expectEqual(merged1.rawLines, ocrLines1, "1: rawLines are the OCR lines")
expectEqual(merged1.kind, .conferenceLanyard, "1: kind is carried from the detector")
expectTrue(merged1.badgeRect == rect1, "1: badgeRect is carried from the detector")

// 2. Barcode named + OCR parsed nothing (no lines recognised at all): a
// named badge from the barcode alone, and rawLines fall back to the
// barcode's own payload rather than an empty OCR list.
let fullBarcode = BarcodeReader.parse(vcard)!
let merged2 = BadgeParser.merge(barcode: fullBarcode, lines: [], kind: nil, rect: rect2)
expectEqual(merged2.name, "Sarah Chen", "2: barcode's name wins")
expectEqual(merged2.source, .barcode, "2: barcode source wins")
expectEqual(merged2.title, "Radiologist", "2: barcode's own title is kept")
expectEqual(merged2.org, "Auckland City Hospital", "2: barcode's own org is kept")
expectEqual(merged2.rawLines, fullBarcode.rawLines,
            "2: rawLines fall back to the barcode's own")
expectTrue(merged2.kind == nil, "2: no kind was supplied")
expectTrue(merged2.badgeRect == rect2, "2: badgeRect is still carried")

// 3. No barcode + OCR parsed: an .onDevice badge from OCR alone.
let merged3 = BadgeParser.merge(
    barcode: nil, lines: ["Sarah Chen", "Radiology"], kind: nil, rect: rect3)
expectEqual(merged3.name, "Sarah Chen", "3: OCR's name is used")
expectEqual(merged3.source, .onDevice, "3: on-device source, no barcode")
expectEqual(merged3.title, "Radiology", "3: OCR's leftover line is the title")
expectTrue(merged3.barcodePayload == nil, "3: no barcode payload to carry")
expectTrue(merged3.badgeRect == rect3, "3: badgeRect is still carried")

// 4. Unnamed barcode + OCR parsed: the OCR badge wins the name, but the
// unnamed barcode's payload rides along rather than being discarded.
let opaqueBarcode = BarcodeReader.parse("ATT-4471")!
expectTrue(opaqueBarcode.name == nil, "fixture: an opaque id names nobody")
let merged4 = BadgeParser.merge(
    barcode: opaqueBarcode, lines: ["Sarah Chen"], kind: nil, rect: rect4)
expectEqual(merged4.name, "Sarah Chen", "4: OCR's name is used")
expectEqual(merged4.source, .onDevice, "4: on-device source, the barcode named nobody")
expectEqual(merged4.barcodePayload, "ATT-4471",
            "4: the unnamed barcode's payload is carried forward")

// 5. Nothing readable: still a non-nil badge - located but unreadable -
// with kind and badgeRect set, and an opaque barcode payload retained.
let merged5 = BadgeParser.merge(
    barcode: opaqueBarcode, lines: [], kind: .handheldID, rect: rect5)
expectTrue(merged5.name == nil, "5: nothing was readable")
expectEqual(merged5.kind, .handheldID, "5: kind is still set")
expectTrue(merged5.badgeRect == rect5, "5: badgeRect is still set")
expectEqual(merged5.barcodePayload, "ATT-4471",
            "5: the opaque barcode payload is still retained")
expectEqual(merged5.rawLines, [], "5: no lines were read")

// 6. An unknown detector label still yields a badge, never nil - `merge`'s
// return type is non-optional, so the only way to honour that is for the
// nil kind to flow through untouched instead of being special-cased away.
let unknownKind = Badge.Kind(detectorLabel: "unknown_widget")
expectTrue(unknownKind == nil, "fixture: an unrecognised label maps to no kind")
let merged6 = BadgeParser.merge(barcode: nil, lines: [], kind: unknownKind, rect: rect6)
expectTrue(merged6.kind == nil, "6: an unknown kind still produces a badge, kind nil")
expectTrue(merged6.name == nil, "6: nothing was readable")
expectTrue(merged6.badgeRect == rect6, "6: badgeRect is still set")

// MARK: - BadgeParser.preferred - detected vs. the band fallback
//
// Once a model ships, a detected box that names nobody (a false positive,
// or a real badge the crop couldn't read) must not shut the band out of a
// region it might still read - see BadgeReader.readBadge. The choice
// between the two already-computed results is pure and lives here; the
// decision of whether to bother running the band pass at all is
// BadgeReader's job and needs Vision, so it isn't tested in this suite.

let detectedNamed = Badge(
    name: "Dana Lee", source: .onDevice, kind: .corporateID, badgeRect: rect1)
let fallbackNamed = Badge(name: "Priya Singh", source: .onDevice)

// A: detected named, fallback named -> detected wins outright, untouched.
let prefA = BadgeParser.preferred(detected: detectedNamed, fallback: fallbackNamed)
expectEqual(prefA.name, "Dana Lee", "A: a named detection is never overridden")
expectEqual(prefA.kind, .corporateID, "A: detected's own kind survives")
expectTrue(prefA.badgeRect == rect1, "A: detected's own rect survives")

let detectedNameless = Badge(
    source: .onDevice, kind: .handheldID, barcodePayload: "XYZ-1", badgeRect: rect2)

// B: detected nameless, fallback named -> the band's name wins, but the
// detected badge's kind/badgeRect/barcodePayload are carried forward - the
// band pass produces none of those itself.
let fallbackWithTitle = Badge(name: "Priya Singh", title: "Engineer", source: .onDevice)
let prefB = BadgeParser.preferred(detected: detectedNameless, fallback: fallbackWithTitle)
expectEqual(prefB.name, "Priya Singh", "B: the band's name is used")
expectEqual(prefB.title, "Engineer", "B: the band's own title is kept")
expectEqual(prefB.kind, .handheldID, "B: detected's kind is carried forward")
expectTrue(prefB.badgeRect == rect2, "B: detected's rect is carried forward")
expectEqual(prefB.barcodePayload, "XYZ-1", "B: detected's barcode payload is carried forward")

// C: detected nameless, fallback nil (band found nothing either) ->
// detected is returned unchanged - still non-nil, name nil, kind/rect/
// payload intact.
let prefC = BadgeParser.preferred(detected: detectedNameless, fallback: nil)
expectTrue(prefC.name == nil, "C: still nothing readable")
expectEqual(prefC.kind, .handheldID, "C: detected's kind survives with no fallback")
expectTrue(prefC.badgeRect == rect2, "C: detected's rect survives with no fallback")
expectEqual(prefC.barcodePayload, "XYZ-1", "C: detected's payload survives with no fallback")

// D: detected nameless, fallback non-nil but ALSO nameless -> detected is
// still returned, because it carries kind/rect/payload the band's empty
// result does not.
let fallbackNameless = Badge(source: .onDevice)
let prefD = BadgeParser.preferred(detected: detectedNameless, fallback: fallbackNameless)
expectTrue(prefD.name == nil, "D: neither pass named anyone")
expectEqual(prefD.kind, .handheldID, "D: detected (not the band) is returned")
expectTrue(prefD.badgeRect == rect2, "D: detected's rect proves detected was kept")
expectEqual(prefD.barcodePayload, "XYZ-1", "D: detected's payload proves detected was kept")

print(failures == 0 ? "\nAll badge tests passed" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
