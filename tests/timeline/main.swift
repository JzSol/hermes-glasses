//
// Standalone tests for EncounterTimeline. No XCTest target, so build via
// swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/Encounter.swift \
//     HermesGlasses/Services/Social/EncounterEvent.swift \
//     HermesGlasses/Services/Social/EncounterTimeline.swift \
//     tests/timeline/main.swift -o /tmp/timeline-tests && /tmp/timeline-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

func sarah(_ source: Badge.Source = .onDevice) -> Badge {
    Badge(name: "Sarah Chen", title: "Radiology", rawLines: ["Sarah Chen"],
          source: source)
}

func photos(_ row: EncounterTimeline.Row) -> [String] {
    if case .sighting(let files, _) = row.content { return files }
    return []
}
func badge(_ row: EncounterTimeline.Row) -> Badge? {
    if case .sighting(_, let badge) = row.content { return badge }
    return nil
}
func speech(_ row: EncounterTimeline.Row) -> String? {
    if case .speech(let text) = row.content { return text }
    return nil
}

// MARK: - Ordering

let unordered = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.speech("third", at: at(30)),
    EncounterEvent.speech("first", at: at(10)),
    EncounterEvent.speech("second", at: at(20)),
])
let ordered = EncounterTimeline.build(unordered)
expectEqual(ordered.kind, .conversation, "events mean a conversation")
expectEqual(ordered.rows.compactMap(speech), ["first", "second", "third"],
            "rows sort by timestamp")

// Ties keep insertion order.
let tied = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.speech("a", at: at(10)),
    EncounterEvent.speech("b", at: at(10)),
])
expectEqual(EncounterTimeline.build(tied).rows.compactMap(speech), ["a", "b"],
            "equal timestamps keep insertion order")

// MARK: - Badge grouping

let repeated = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.sighting(photoFilenames: ["1.jpg"], badge: sarah(), at: at(10)),
    EncounterEvent.speech("hello", at: at(15)),
    EncounterEvent.sighting(photoFilenames: ["2.jpg"], at: at(20)),
    EncounterEvent.sighting(photoFilenames: ["3.jpg"], badge: sarah(), at: at(30)),
])
let grouped = EncounterTimeline.build(repeated)
expectEqual(grouped.rows.count, 3, "two Sarah sightings collapse into one row")
expectEqual(photos(grouped.rows[0]), ["1.jpg", "3.jpg"], "merged row gathers photos")
expectEqual(grouped.rows[0].timestamp, at(10), "merged row keeps the earliest time")
expectEqual(speech(grouped.rows[1]), "hello", "speech is untouched by merging")
expectEqual(photos(grouped.rows[2]), ["2.jpg"], "unbadged sighting stays separate")
expectEqual(badge(grouped.rows[2]), nil, "unbadged sighting has no badge")

// Two different names never merge.
let twoPeople = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.sighting(photoFilenames: ["1.jpg"], badge: sarah(), at: at(10)),
    EncounterEvent.sighting(
        photoFilenames: ["2.jpg"],
        badge: Badge(name: "Alan Turing", rawLines: [], source: .onDevice),
        at: at(20)),
])
expectEqual(EncounterTimeline.build(twoPeople).rows.count, 2,
            "different names stay separate rows")

// Two unbadged sightings never merge with each other.
let twoUnknown = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.sighting(photoFilenames: ["1.jpg"], at: at(10)),
    EncounterEvent.sighting(photoFilenames: ["2.jpg"], at: at(20)),
])
expectEqual(EncounterTimeline.build(twoUnknown).rows.count, 2,
            "unbadged sightings never merge with each other")

// MARK: - Source priority on merge

let mixedSources = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.sighting(photoFilenames: ["1.jpg"], badge: sarah(.assisted), at: at(10)),
    EncounterEvent.sighting(photoFilenames: ["2.jpg"], badge: sarah(.manual), at: at(20)),
])
expectEqual(EncounterTimeline.build(mixedSources).rows.first.flatMap(badge)?.source,
            .manual, "manual badge wins the merge")

// Reverse order: manual arrives first, assisted second - manual still wins
// (tie-break must not simply be "last one in").
let mixedSourcesReversed = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.sighting(photoFilenames: ["1.jpg"], badge: sarah(.manual), at: at(10)),
    EncounterEvent.sighting(photoFilenames: ["2.jpg"], badge: sarah(.assisted), at: at(20)),
])
expectEqual(EncounterTimeline.build(mixedSourcesReversed).rows.first.flatMap(badge)?.source,
            .manual, "manual badge wins the merge even when it arrives first")

// MARK: - Legacy synthesis

let single = Encounter(note: "Sarah from the AR team", timestamp: t0,
                       photoFilenames: ["one.jpg"], events: [])
let singleTimeline = EncounterTimeline.build(single)
expectEqual(singleTimeline.kind, .singleNote, "one photo and a note is a single note")
expectEqual(singleTimeline.rows.count, 2, "legacy single yields a photo row and a note row")
expectEqual(photos(singleTimeline.rows[0]), ["one.jpg"], "legacy photo row")
expectEqual(speech(singleTimeline.rows[1]), "Sarah from the AR team", "legacy note row")

let legacyMulti = Encounter(note: "line", timestamp: t0,
                            photoFilenames: ["a.jpg", "b.jpg", "c.jpg"], events: [])
expectEqual(EncounterTimeline.build(legacyMulti).kind, .conversation,
            "several legacy photos read as a conversation")

let noteOnly = Encounter(note: "just a note", timestamp: t0,
                         photoFilenames: [], events: [])
let noteOnlyTimeline = EncounterTimeline.build(noteOnly)
expectEqual(noteOnlyTimeline.kind, .singleNote, "note with no photo is a single note")
expectEqual(noteOnlyTimeline.rows.count, 1, "note-only yields one row")

let empty = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [])
expectEqual(EncounterTimeline.build(empty).rows.count, 0, "nothing yields no rows")
expectEqual(EncounterTimeline.build(empty).kind, .singleNote, "nothing is a single note")

// Legacy row ids are deterministic, so SwiftUI does not rebuild them.
expectEqual(EncounterTimeline.build(single).rows.map(\.id),
            EncounterTimeline.build(single).rows.map(\.id),
            "legacy row ids are stable across builds")

// Legacy row ids are not UUIDs - Task 10 relies on this to identify
// non-editable legacy rows via UUID(uuidString:) returning nil.
expectTrue(UUID(uuidString: singleTimeline.rows[0].id) == nil,
           "legacy photo row id is not a UUID")
expectTrue(UUID(uuidString: singleTimeline.rows[1].id) == nil,
           "legacy note row id is not a UUID")

// MARK: - Row.eventIDs (fix round 1: renaming a merged row must not split it)

// `repeated` above: two Sarah sightings (event 0 and event 3) merge into
// rows[0]; a lone unbadged sighting (event 2) is rows[2].
let sarahEvents = repeated.events.filter {
    if case .sighting = $0.kind { return $0.badge?.name == "Sarah Chen" }
    return false
}
expectEqual(grouped.rows[0].eventIDs, sarahEvents.map(\.id),
            "merged row's eventIDs contains both contributing events, in order")

let unbadgedEvent = repeated.events.first { $0.kind == .sighting && $0.badge == nil }!
expectEqual(grouped.rows[2].eventIDs, [unbadgedEvent.id],
            "a lone sighting has exactly one eventID")

let speechEvent = repeated.events.first { event in
    event.kind == .speech && event.text == "hello"
}!
expectEqual(grouped.rows[1].eventIDs, [speechEvent.id],
            "a speech row has exactly one eventID")

expectEqual(singleTimeline.rows[0].eventIDs, [], "legacy photo row has no eventIDs")
expectEqual(singleTimeline.rows[1].eventIDs, [], "legacy note row has no eventIDs")

// MARK: - Regression: renaming a merged row must not split it back apart
//
// This is the actual regression test for the bug in Finding 1. It lives here
// (rather than in tests/encounters/main.swift, alongside the
// EncounterStore.updateBadgeName test) because this suite's own documented
// build command does not compile in EncounterStore.swift, and the bug is
// fundamentally about EncounterTimeline.build's regrouping - EncounterStore
// is only the mechanism that must keep both events' names in sync to avoid
// it, which the encounters suite verifies separately.

// Pre-fix shape: only the row's first event got renamed, so the two events
// now carry DIFFERENT names and their groupKeys diverge - this is exactly
// what used to happen, and it splits the row in two.
let staleRename = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.sighting(
        photoFilenames: ["1.jpg"],
        badge: Badge(name: "John Smith", rawLines: ["Jhon Smith"], source: .manual),
        at: at(10)),
    EncounterEvent.sighting(
        photoFilenames: ["2.jpg"],
        badge: Badge(name: "Jhon Smith", rawLines: ["JHON SMITH"], source: .onDevice),
        at: at(20)),
])
expectEqual(EncounterTimeline.build(staleRename).rows.count, 2,
            "renaming only ONE of a merged row's events splits it back apart (the bug)")

// Fixed shape: EncounterStore.updateBadgeName (tested in tests/encounters)
// unifies the name across every eventID the row was built from, so both
// events carry the SAME corrected name and the row stays merged.
let unifiedRename = Encounter(note: "", timestamp: t0, photoFilenames: [], events: [
    EncounterEvent.sighting(
        photoFilenames: ["1.jpg"],
        badge: Badge(name: "John Smith", rawLines: ["Jhon Smith"], source: .manual),
        at: at(10)),
    EncounterEvent.sighting(
        photoFilenames: ["2.jpg"],
        badge: Badge(name: "John Smith", rawLines: ["JHON SMITH"], source: .manual),
        at: at(20)),
])
let unifiedTimeline = EncounterTimeline.build(unifiedRename)
expectEqual(unifiedTimeline.rows.count, 1,
            "renaming BOTH of a merged row's events keeps it as one row (the fix)")
expectEqual(photos(unifiedTimeline.rows[0]), ["1.jpg", "2.jpg"],
            "the reunified row still gathers both photos")
expectEqual(unifiedTimeline.rows[0].eventIDs.count, 2,
            "the reunified row's eventIDs still cover both events")

print(failures == 0 ? "\nAll timeline tests passed" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
