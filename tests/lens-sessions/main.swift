//
// Standalone tests for LensSessionStore. No XCTest target, build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Lens/LensSession.swift \
//     HermesGlasses/Services/Lens/LensSessionStore.swift \
//     tests/lens-sessions/main.swift -o /tmp/lens-sessions-tests && /tmp/lens-sessions-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("lens-sessions-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

let cropBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22])
let store = LensSessionStore(directory: root)

// Empty to start
expectEqual(store.all().count, 0, "empty store")

// Save a session with two entries (one with a crop, one without)
let start = Date(timeIntervalSince1970: 2_000_000)
let end = start.addingTimeInterval(45)
let saved = store.save(
    startedAt: start, endedAt: end,
    entries: [
        LensSessionInput(label: "person", totalLookTime: 14.2, lookCount: 3, photo: cropBytes),
        LensSessionInput(label: "cup", totalLookTime: 5.0, lookCount: 2, photo: nil),
    ]
)
expectEqual(saved.entries.count, 2, "two entries saved")
expectEqual(saved.entries[0].label, "person", "first entry label")
expectEqual(saved.entries[0].lookCount, 3, "look count persisted")
expectTrue(!saved.entries[0].photoFilename.isEmpty, "crop got a filename")
expectTrue(saved.entries[1].photoFilename.isEmpty, "no filename without a crop")
expectEqual(store.photoData(for: saved.entries[0]), cropBytes, "crop round-trips")
expectTrue(store.photoData(for: saved.entries[1]) == nil, "no crop data for entry 2")

// all() returns saved sessions
expectEqual(store.all().count, 1, "one session after save")

// A second store over the same directory reloads the index
let reopened = LensSessionStore(directory: root)
expectEqual(reopened.all().count, 1, "index reloads from disk")
expectEqual(reopened.all()[0].entries.count, 2, "entries reload")

// newest-first ordering
let later = store.save(
    startedAt: end.addingTimeInterval(100), endedAt: end.addingTimeInterval(160),
    entries: [LensSessionInput(label: "chair", totalLookTime: 2.0, lookCount: 1, photo: cropBytes)]
)
expectEqual(store.all().first?.id, later.id, "newest session first")

// Delete removes the session and its crop file
store.delete(id: saved.id)
expectEqual(store.all().count, 1, "one left after delete")
expectTrue(store.photoData(for: saved.entries[0]) == nil, "deleted crop file gone")

// Deleting an id that isn't there must not rewrite the index: the file is
// removed by hand here, and a rewrite would put it straight back.
let untouchedRoot = root.appendingPathComponent("untouched")
let untouchedStore = LensSessionStore(directory: untouchedRoot)
untouchedStore.save(
    startedAt: start, endedAt: end,
    entries: [LensSessionInput(label: "mug", totalLookTime: 1, lookCount: 1,
                               photo: cropBytes)]
)
_ = LensSessionStore(directory: untouchedRoot)  // waits for the queued write
let untouchedIndex = untouchedRoot.appendingPathComponent("sessions.json")
try? FileManager.default.removeItem(at: untouchedIndex)
untouchedStore.delete(id: UUID())
_ = LensSessionStore(directory: untouchedRoot)  // waits again, if anything ran
expectTrue(!FileManager.default.fileExists(atPath: untouchedIndex.path),
           "deleting an unknown id does not rewrite the index")

if failures > 0 { print("\n\(failures) FAILURES"); exit(1) }
print("\nAll lens-sessions tests passed")
