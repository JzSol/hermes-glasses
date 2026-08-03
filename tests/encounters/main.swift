//
// Standalone tests for EncounterStore. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/Encounter.swift \
//     HermesGlasses/Services/Social/EncounterEvent.swift \
//     HermesGlasses/Services/Social/EncounterStore.swift \
//     tests/encounters/main.swift -o /tmp/encounter-tests && /tmp/encounter-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("encounter-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

let eventBase = Date(timeIntervalSince1970: 2_000_000)
func at2(_ offset: TimeInterval) -> Date { eventBase.addingTimeInterval(offset) }

let photoBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
let store = EncounterStore(directory: root)

// Empty to start
expectEqual(store.all().count, 0, "empty store")

// Save with a photo
let now = Date()
let withPhoto = store.save(note: "  Sarah from Meta, AR input  ", photo: photoBytes,
                           timestamp: now)
expectEqual(withPhoto.note, "Sarah from Meta, AR input", "note is trimmed")
expectTrue(withPhoto.photoFilename != nil, "photo filename assigned")
expectEqual(store.photoData(for: withPhoto), photoBytes, "photo round-trips")

// Save without a photo (camera failure path)
let noPhoto = store.save(note: "Guy in the red jacket", photo: nil,
                         timestamp: now.addingTimeInterval(60))
expectTrue(noPhoto.photoFilename == nil, "no filename without a photo")
expectTrue(store.photoData(for: noPhoto) == nil, "no photo data")

// Empty note (the silence-timeout path) is still a valid entry
let silent = store.save(note: "", photo: photoBytes,
                        timestamp: now.addingTimeInterval(120))
expectEqual(silent.note, "", "empty note allowed")

// Newest first
expectEqual(store.all().map(\.id), [silent.id, noPhoto.id, withPhoto.id],
            "all() is newest first")

// Edit
store.update(id: withPhoto.id, note: "Sarah - send the demo link")
expectEqual(store.all().first(where: { $0.id == withPhoto.id })?.note,
            "Sarah - send the demo link", "note updated")

// Reload from disk: a fresh store over the same directory sees everything
let reopened = EncounterStore(directory: root)
expectEqual(reopened.all().count, 3, "index persisted")
expectEqual(reopened.all().first(where: { $0.id == withPhoto.id })?.note,
            "Sarah - send the demo link", "edit persisted")
expectEqual(reopened.photoData(for: withPhoto), photoBytes, "photo persisted")

// Delete removes the row and its photo file
let photoPath = root.appendingPathComponent("photos")
    .appendingPathComponent(withPhoto.photoFilename ?? "missing")
expectTrue(FileManager.default.fileExists(atPath: photoPath.path), "photo on disk")
reopened.delete(id: withPhoto.id)
expectEqual(reopened.all().count, 2, "row deleted")
expectTrue(!FileManager.default.fileExists(atPath: photoPath.path), "photo file deleted")
expectEqual(EncounterStore(directory: root).all().count, 2, "delete persisted")

// Unknown ids are no-ops, not crashes
reopened.update(id: UUID(), note: "nobody")
reopened.delete(id: UUID())
expectEqual(reopened.all().count, 2, "unknown id is a no-op")

// Multi-photo save (conversation capture): every photo lands on disk
let photoA = Data([0xFF, 0xD8, 0x0A])
let photoB = Data([0xFF, 0xD8, 0x0B])
let multi = reopened.save(note: "Team standup with Sarah and Raj",
                          photos: [photoA, photoB],
                          timestamp: now.addingTimeInterval(300))
expectEqual(multi.photoFilenames.count, 2, "two filenames assigned")
expectEqual(reopened.photoDatas(for: multi), [photoA, photoB], "photos round-trip in order")
expectEqual(multi.photoFilename, multi.photoFilenames.first, "legacy accessor is the first photo")
expectEqual(reopened.photoData(for: multi), photoA, "single-photo read serves the first")

// Multi-photo persists and deletes all its files
let reopened2 = EncounterStore(directory: root)
expectEqual(reopened2.photoDatas(for: multi).count, 2, "multi-photo persisted")
let multiPaths = multi.photoFilenames.map {
    root.appendingPathComponent("photos").appendingPathComponent($0)
}
reopened2.delete(id: multi.id)
expectTrue(multiPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
           "all photo files deleted")

// Legacy index (single photoFilename key) still decodes
let legacyRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("encounter-legacy-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: legacyRoot) }
try? FileManager.default.createDirectory(
    at: legacyRoot.appendingPathComponent("photos"), withIntermediateDirectories: true)
let legacyJSON = """
[{"id":"11111111-2222-3333-4444-555555555555","note":"old-format entry",
"timestamp":"2026-07-10T12:00:00Z","photoFilename":"legacy.jpg"},
{"id":"11111111-2222-3333-4444-666666666666","note":"old note-only entry",
"timestamp":"2026-07-10T13:00:00Z"}]
"""
try? legacyJSON.data(using: .utf8)!.write(
    to: legacyRoot.appendingPathComponent("encounters.json"))
let legacyStore = EncounterStore(directory: legacyRoot)
expectEqual(legacyStore.all().count, 2, "legacy index decodes")
expectEqual(legacyStore.all().last?.photoFilenames, ["legacy.jpg"],
            "legacy photoFilename migrates into the array")
expectEqual(legacyStore.all().first?.photoFilenames, [],
            "legacy note-only entry has no photos")

// MARK: - Badge

let badge = Badge(name: "Sarah Chen", title: "Radiology",
                  org: "Auckland City Hospital",
                  rawLines: ["Dr. Sarah Chen", "RADIOLOGY"], source: .onDevice)
expectEqual(badge.subtitle, "Radiology · Auckland City Hospital", "badge subtitle joins")
expectEqual(Badge(name: "Sarah Chen", rawLines: [], source: .onDevice).subtitle,
            nil, "badge with no title or org has no subtitle")
expectEqual(badge.groupKey, "sarah chen", "group key normalizes")
expectEqual(Badge(name: "  Dr.  SARAH   Chen! ", rawLines: [], source: .onDevice).groupKey,
            "dr sarah chen", "group key strips punctuation and collapses spaces")
expectEqual(Badge(rawLines: [], source: .assisted).groupKey, nil, "no name means no group key")
expectTrue(Badge.Source.manual.rank > Badge.Source.onDevice.rank, "manual outranks on-device")
expectTrue(Badge.Source.onDevice.rank > Badge.Source.assisted.rank, "on-device outranks assisted")

// MARK: - EncounterEvent derived fields

let t0 = Date(timeIntervalSince1970: 1_000_000)
let derivedEvents = [
    EncounterEvent.sighting(photoFilenames: ["a.jpg"], badge: badge, at: t0),
    EncounterEvent.speech("Nice to meet you", at: t0.addingTimeInterval(1)),
    EncounterEvent.speech("Third floor now", at: t0.addingTimeInterval(2)),
    EncounterEvent.sighting(photoFilenames: ["b.jpg", "c.jpg"], at: t0.addingTimeInterval(3)),
]
expectEqual(EncounterEvent.derivedNote(derivedEvents),
            "Nice to meet you\nThird floor now", "derived note joins speech only")
expectEqual(EncounterEvent.derivedPhotoFilenames(derivedEvents),
            ["a.jpg", "b.jpg", "c.jpg"], "derived filenames follow sighting order")

// MARK: - Encounter codable round-trip with events

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

let withEvents = Encounter(note: "n", timestamp: t0,
                           photoFilenames: ["a.jpg"], events: derivedEvents)
let roundTripped = try! decoder.decode(
    Encounter.self, from: try! encoder.encode(withEvents))
expectEqual(roundTripped, withEvents, "encounter with events round-trips")
expectEqual(roundTripped.events.first?.badge?.name, "Sarah Chen", "badge survives round-trip")

// Index written before the timeline existed: no `events` key at all.
// NOTE: named `timelineLegacyJSON` because this file already declares a
// top-level `legacyJSON` at line ~103 for the photoFilename migration.
let timelineLegacyJSON = """
[{"id":"\(UUID().uuidString)","note":"old","timestamp":"1970-01-12T13:46:40Z",\
"photoFilename":"old.jpg"}]
""".data(using: .utf8)!
let legacyDecoded = try! decoder.decode([Encounter].self, from: timelineLegacyJSON)
expectEqual(legacyDecoded.first?.events.count, 0, "legacy entry decodes with no events")
expectEqual(legacyDecoded.first?.photoFilenames, ["old.jpg"], "legacy photo still migrates")

// MARK: - Event-stream save

let eventStore = EncounterStore(directory: root.appendingPathComponent("events"))
let jpegA = Data([0xFF, 0xD8, 0x01])
let jpegB = Data([0xFF, 0xD8, 0x02])

let sightingID = UUID()
let captured: [CapturedEvent] = [
    CapturedEvent(id: sightingID, kind: .sighting, timestamp: at2(0), photoIndex: 0),
    CapturedEvent(kind: .speech, timestamp: at2(5), text: "Nice to meet you"),
    CapturedEvent(kind: .speech, timestamp: at2(9), text: "Third floor now"),
    CapturedEvent(kind: .sighting, timestamp: at2(12), photoIndex: 1,
                  badge: Badge(name: "Alan Turing", rawLines: ["Alan Turing"],
                               source: .onDevice)),
    // A sighting whose crop failed: no photo, but it still happened.
    CapturedEvent(kind: .sighting, timestamp: at2(20), photoIndex: nil),
]
let savedEvents = eventStore.save(events: captured, photos: [jpegA, jpegB],
                                  timestamp: at2(0))

expectEqual(savedEvents.events.count, 5, "every captured event is stored")
expectEqual(savedEvents.note, "Nice to meet you\nThird floor now",
            "note is derived from speech")
expectEqual(savedEvents.photoFilenames.count, 2, "photoFilenames is derived")
expectEqual(savedEvents.events[0].photoFilenames.count, 1, "photo index 0 resolved")
expectEqual(savedEvents.events[4].photoFilenames, [], "nil photo index gives no file")
expectEqual(savedEvents.events[1].photoFilenames, [], "speech has no photos")
expectEqual(eventStore.photoData(filename: savedEvents.events[0].photoFilenames[0]),
            jpegA, "photo bytes land under the resolved filename")

// Badge fill-in, as the deferred assist pass and a manual edit both do it.
let newBadge = Badge(name: "Sarah Chen", title: "Radiology",
                     rawLines: ["Sarah Chen"], source: .assisted)
eventStore.update(encounterID: savedEvents.id, eventID: sightingID, badge: newBadge)
let reread = EncounterStore(directory: root.appendingPathComponent("events"))
let rereadEncounter = reread.all().first { $0.id == savedEvents.id }
expectEqual(rereadEncounter?.events.first?.badge?.name, "Sarah Chen",
            "badge update survives a reload")
expectEqual(rereadEncounter?.events.first?.badge?.source, .assisted,
            "badge source survives a reload")

// Unknown ids are a no-op, not a crash.
eventStore.update(encounterID: UUID(), eventID: sightingID, badge: nil)
eventStore.update(encounterID: savedEvents.id, eventID: UUID(), badge: nil)
expectEqual(eventStore.all().first { $0.id == savedEvents.id }?.events.first?.badge?.name,
            "Sarah Chen", "unknown ids leave the badge alone")

expectEqual(eventStore.photoData(filename: "missing.jpg"), nil,
            "a missing photo file reads as nil")

// MARK: - updateBadgeName (fix round 1: renaming a merged row)

// Two sightings both misread as "Jhon Smith" - the pre-fix bug renamed only
// the row's first event, leaving the second event's stale name to split the
// row back apart on the next render.
let renameStore = EncounterStore(directory: root.appendingPathComponent("rename"))
let misreadA = UUID()
let misreadB = UUID()
let renameCaptured: [CapturedEvent] = [
    CapturedEvent(id: misreadA, kind: .sighting, timestamp: at2(0), photoIndex: 0,
                  badge: Badge(name: "Jhon Smith", rawLines: ["Jhon Smith", "Engineer"],
                               source: .onDevice)),
    CapturedEvent(id: misreadB, kind: .sighting, timestamp: at2(10), photoIndex: 1,
                  badge: Badge(name: "Jhon Smith", rawLines: ["JHON SMITH"],
                               source: .onDevice)),
]
let renameSaved = renameStore.save(
    events: renameCaptured, photos: [jpegA, jpegB], timestamp: at2(0))

renameStore.updateBadgeName(
    encounterID: renameSaved.id, eventIDs: [misreadA, misreadB], name: "John Smith")

let renameReloaded = EncounterStore(directory: root.appendingPathComponent("rename"))
let renameEncounter = renameReloaded.all().first { $0.id == renameSaved.id }!
let renamedA = renameEncounter.events.first { $0.id == misreadA }!
let renamedB = renameEncounter.events.first { $0.id == misreadB }!

expectEqual(renamedA.badge?.name, "John Smith", "first event's name is corrected")
expectEqual(renamedB.badge?.name, "John Smith", "second event's name is ALSO corrected")
expectEqual(renamedA.badge?.source, .manual, "first event's source becomes manual")
expectEqual(renamedB.badge?.source, .manual, "second event's source becomes manual")
expectEqual(renamedA.badge?.rawLines, ["Jhon Smith", "Engineer"],
            "first event keeps its own rawLines - only the name is unified")
expectEqual(renamedB.badge?.rawLines, ["JHON SMITH"],
            "second event keeps its own rawLines - only the name is unified")

// The row-count regression assertion ("EncounterTimeline.build still yields
// ONE row") lives in tests/timeline/main.swift instead of here: this file's
// own build command (see header) does not compile in EncounterTimeline.swift,
// so an EncounterTimeline.build(_:) call here would not build under the
// documented `xcrun swiftc ... tests/encounters/main.swift` invocation.

// Unknown eventIDs in the list are skipped, not a crash; known ones still land.
renameStore.updateBadgeName(
    encounterID: renameSaved.id, eventIDs: [misreadA, UUID()], name: "Jonathan Smith")
let renameReloaded2 = EncounterStore(directory: root.appendingPathComponent("rename"))
expectEqual(
    renameReloaded2.all().first { $0.id == renameSaved.id }?.events
        .first { $0.id == misreadA }?.badge?.name,
    "Jonathan Smith", "a real eventID in a mixed list still updates")

// Extra: out-of-range photo indices resolve to no photo, not a crash.
let oobStore = EncounterStore(directory: root.appendingPathComponent("events-oob"))
let oobEvents: [CapturedEvent] = [
    CapturedEvent(kind: .sighting, timestamp: at2(0), photoIndex: 5),
    CapturedEvent(kind: .sighting, timestamp: at2(1), photoIndex: -1),
]
let oobSaved = oobStore.save(events: oobEvents, photos: [jpegA], timestamp: at2(0))
expectEqual(oobSaved.events[0].photoFilenames, [], "out-of-range positive index gives no file")
expectEqual(oobSaved.events[1].photoFilenames, [], "negative index gives no file")
expectEqual(oobSaved.photoFilenames, [], "derived photoFilenames stays empty for out-of-range indices")

// MARK: - Recordings

let recStore = EncounterStore(directory: root.appendingPathComponent("recordings"))
let recSaved = recStore.save(note: "with audio", photos: [], timestamp: at2(0))
expectTrue(recSaved.audioFilename == nil, "an encounter starts with no recording")
expectTrue(recStore.recordingURL(for: recSaved) == nil, "no recording, no URL")

let staged = recStore.stagingRecordingURL()
try? Data("fake wav".utf8).write(to: staged)
let attached = recStore.attachRecording(encounterID: recSaved.id, from: staged)
expectTrue(attached != nil, "attachRecording returns the adopted file")
expectTrue(
    !FileManager.default.fileExists(atPath: staged.path),
    "the staged file is MOVED, not copied - an hour of audio is not duplicated")

let recReread = recStore.all().first { $0.id == recSaved.id }
expectEqual(recReread?.audioFilename, "\(recSaved.id.uuidString).wav",
            "the recording is filed under the encounter's id")
expectTrue(recStore.recordingURL(for: recReread!) != nil, "the recording resolves back")

// Attaching a file that isn't there must not invent a filename - the entry
// would then claim audio that cannot be played or transcribed.
let ghost = recStore.stagingRecordingURL()
expectTrue(
    recStore.attachRecording(encounterID: recSaved.id, from: ghost) == nil,
    "attaching a missing file is a no-op")

// Deleting takes the recording with it.
let audioURL = recStore.recordingURL(for: recReread!)!
recStore.delete(id: recSaved.id)
expectTrue(
    !FileManager.default.fileExists(atPath: audioURL.path),
    "deleting an encounter deletes its recording")

// MARK: - Transcript replacement

let txStore = EncounterStore(directory: root.appendingPathComponent("transcript"))
let txEvents: [CapturedEvent] = [
    CapturedEvent(kind: .speech, timestamp: at2(0), text: "hi there"),
    CapturedEvent(kind: .sighting, timestamp: at2(30), photoIndex: 0),
    CapturedEvent(kind: .speech, timestamp: at2(60), text: "what do you do"),
]
let txSaved = txStore.save(events: txEvents, photos: [jpegA], timestamp: at2(0))
let photoBefore = txSaved.events.first { $0.kind == .sighting }?.photoFilenames

txStore.replaceTranscript(
    encounterID: txSaved.id,
    lines: ["Hi there.", "What do you do?", "I'm a radiographer."])
let txAfter = txStore.all().first { $0.id == txSaved.id }!

expectEqual(txAfter.events.filter { $0.kind == .speech }.map(\.text),
            ["Hi there.", "What do you do?", "I'm a radiographer."],
            "speech events are replaced by the better transcript")
expectEqual(txAfter.events.filter { $0.kind == .sighting }.count, 1,
            "sightings survive re-transcription")
expectEqual(txAfter.events.first { $0.kind == .sighting }?.photoFilenames,
            photoBefore, "the sighting keeps its photo")
expectEqual(txAfter.note, "Hi there.\nWhat do you do?\nI'm a radiographer.",
            "the derived note is rebuilt from the new transcript")
expectTrue(
    txAfter.events.map(\.timestamp) == txAfter.events.map(\.timestamp).sorted(),
    "the merged timeline stays in chronological order")

// A failed transcription must never blank a transcript that was heard live.
txStore.replaceTranscript(encounterID: txSaved.id, lines: [])
let txUntouched = txStore.all().first { $0.id == txSaved.id }!
expectEqual(txUntouched.events.filter { $0.kind == .speech }.count, 3,
            "an empty transcription is ignored, not applied")

// A capture with no speech at all - the exact case the recorder exists for -
// must still accept a transcript.
let silentStore = EncounterStore(directory: root.appendingPathComponent("silent"))
let silentSaved = silentStore.save(
    events: [CapturedEvent(kind: .sighting, timestamp: at2(0), photoIndex: 0)],
    photos: [jpegA], timestamp: at2(0))
silentStore.replaceTranscript(encounterID: silentSaved.id, lines: ["Recovered."])
let silentAfter = silentStore.all().first { $0.id == silentSaved.id }!
expectEqual(silentAfter.events.filter { $0.kind == .speech }.map(\.text),
            ["Recovered."],
            "a capture the live recogniser heard nothing in still gets a transcript")

// MARK: - Disk writes are deferred but ordered

// Photo bytes now go out on the store's disk queue, so a read taken the
// instant save returns is the case that has to keep working - the People
// screen loads a thumbnail immediately after a capture ends.
let asyncStore = EncounterStore(directory: root.appendingPathComponent("async"))
let asyncSaved = asyncStore.save(note: "just saved", photo: photoBytes)
expectEqual(asyncStore.photoData(for: asyncSaved), photoBytes,
            "a photo is readable the moment save returns")
expectEqual(
    EncounterStore(directory: root.appendingPathComponent("async"))
        .all().count, 1,
    "a store reopened straight after a save sees the index")

// Concurrent mutators must not lose an update. writeIndex used to snapshot at
// the call site, so two threads could enqueue out of order and persist the
// older state last.
let raceRoot = root.appendingPathComponent("race")
let raceStore = EncounterStore(directory: raceRoot)
let raceIDs = (0..<20).map { raceStore.save(note: "n\($0)", photo: nil).id }
DispatchQueue.concurrentPerform(iterations: raceIDs.count) { index in
    raceStore.update(id: raceIDs[index], note: "updated-\(index)")
}
let raceReloaded = EncounterStore(directory: raceRoot)
expectEqual(raceReloaded.all().count, 20, "every encounter persisted")
expectTrue(raceReloaded.all().allSatisfy { $0.note.hasPrefix("updated-") },
           "no concurrent update is lost to a stale index snapshot")

// Deleting an id that isn't there must not rewrite the index: the file is
// removed by hand here, and a rewrite would put it straight back.
let untouchedRoot = root.appendingPathComponent("untouched")
let untouchedStore = EncounterStore(directory: untouchedRoot)
untouchedStore.save(note: "one", photo: nil)
_ = EncounterStore(directory: untouchedRoot)  // waits for the queued write
let untouchedIndex = untouchedRoot.appendingPathComponent("encounters.json")
try? FileManager.default.removeItem(at: untouchedIndex)
untouchedStore.delete(id: UUID())
_ = EncounterStore(directory: untouchedRoot)  // waits again, if anything ran
expectTrue(!FileManager.default.fileExists(atPath: untouchedIndex.path),
           "deleting an unknown id does not rewrite the index")

// MARK: - Portraits (Task 8): distinct filenames, never in photoFilenames
//
// The privacy-load-bearing invariant: a portrait must be named apart from
// sighting photos (so it can never appear in Encounter.photoFilenames or an
// event's own photoFilenames - both of which feed the People row thumbnail,
// the day grouping, the chat mirror, and the badge-assist payload).

let portraitsRoot = root.appendingPathComponent("portraits")
let portraitStore = EncounterStore(directory: portraitsRoot)
let portraitJPEG = Data([0xFF, 0xD8, 0x0C])
let portraitSightingID = UUID()
let portraitCaptured: [CapturedEvent] = [
    CapturedEvent(id: portraitSightingID, kind: .sighting, timestamp: at2(0),
                  photoIndex: 0, portraitIndex: 0,
                  badge: Badge(name: "Sarah Chen", rawLines: ["Sarah Chen"],
                               source: .onDevice)),
]
let portraitSaved = portraitStore.save(
    events: portraitCaptured, photos: [jpegA], portraits: [portraitJPEG],
    timestamp: at2(0)
)

expectTrue(!portraitSaved.photoFilenames.contains { $0.contains("-portrait-") },
           "encounter.photoFilenames has no portrait entries")
expectEqual(portraitSaved.events[0].photoFilenames, portraitSaved.photoFilenames,
            "the event's photoFilenames is exactly the sighting photo")
expectEqual(portraitSaved.events[0].badge?.portraitFilename,
            "\(portraitSaved.id.uuidString)-portrait-0.jpg",
            "portrait filename follows the <id>-portrait-<n> pattern")
expectEqual(portraitStore.photoData(filename: portraitSaved.events[0].badge!.portraitFilename!),
            portraitJPEG, "portrait bytes read back under their own filename")

// An out-of-range portraitIndex leaves portraitFilename nil - same contract
// as an out-of-range photoIndex a few sections up.
let oobPortraitCaptured: [CapturedEvent] = [
    CapturedEvent(kind: .sighting, timestamp: at2(1), photoIndex: 0,
                  portraitIndex: 5,
                  badge: Badge(name: "Nobody", rawLines: ["Nobody"], source: .onDevice)),
]
let oobPortraitSaved = portraitStore.save(
    events: oobPortraitCaptured, photos: [jpegA], portraits: [portraitJPEG],
    timestamp: at2(1)
)
expectTrue(oobPortraitSaved.events[0].badge?.portraitFilename == nil,
           "out-of-range portraitIndex leaves portraitFilename nil")

// Deleting the encounter must take the portrait with it. Portraits are
// deliberately absent from photoFilenames - that is what keeps them out of
// the badge-assist payload - but that same absence means delete(id:) is the
// ONLY thing that can find them; missing it leaves someone's ID photo on
// disk forever, unreferenced by any index entry. This is the regression
// test for that bug.
let portraitFilename = portraitSaved.events[0].badge!.portraitFilename!
let portraitPath = portraitsRoot.appendingPathComponent("photos")
    .appendingPathComponent(portraitFilename)
expectTrue(FileManager.default.fileExists(atPath: portraitPath.path),
           "portrait file exists before delete")
portraitStore.delete(id: portraitSaved.id)
expectTrue(!FileManager.default.fileExists(atPath: portraitPath.path),
           "portrait file deleted along with the encounter")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
