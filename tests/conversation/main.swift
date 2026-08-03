//
// Standalone tests for ConversationCaptureModel. No XCTest target, so build
// via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Lens/DwellTracker.swift \
//     HermesGlasses/Services/Social/EncounterEvent.swift \
//     HermesGlasses/Services/Social/ConversationCapture.swift \
//     tests/conversation/main.swift -o /tmp/conversation-tests && /tmp/conversation-tests
//
import Foundation
import CoreGraphics

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

// Transcript accumulation: trimmed, empty lines dropped, joined by newline
var model = ConversationCaptureModel()
expectTrue(!model.hasContent, "fresh model has no content")
expectEqual(model.note, "", "fresh model note is empty")

model.addLine("  Hi, I'm Sarah from the AR input team.  ")
model.addLine("")
model.addLine("   ")
model.addLine("We should demo the prototype on Thursday")
expectEqual(model.note,
            "Hi, I'm Sarah from the AR input team.\nWe should demo the prototype on Thursday",
            "note joins trimmed lines, skips blanks")
expectTrue(model.hasContent, "lines count as content")

// Snap gating: first snap always allowed, then minSnapGap apart, capped
var gated = ConversationCaptureModel(maxPhotos: 3, minSnapGap: 10)
expectTrue(gated.recordSnap(at: 100), "first snap allowed")
expectEqual(gated.snapCount, 1, "snap recorded")
expectTrue(!gated.recordSnap(at: 105), "snap inside the gap refused")
expectEqual(gated.snapCount, 1, "refused snap not recorded")
expectTrue(gated.recordSnap(at: 110), "snap at exactly the gap allowed")
expectTrue(gated.recordSnap(at: 130), "third snap allowed")
expectTrue(!gated.recordSnap(at: 200), "cap of 3 refused")
expectEqual(gated.snapCount, 3, "count stays at the cap")

// Photos alone are content (a silent room still met people)
var photosOnly = ConversationCaptureModel()
_ = photosOnly.recordSnap(at: 0)
expectTrue(photosOnly.hasContent, "snaps count as content")

// Person filter at the detection boundary
let people = ConversationCaptureModel.people([
    Detection(label: "person", confidence: 0.9,
              rect: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.5)),
    Detection(label: "chair", confidence: 0.8,
              rect: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)),
    Detection(label: "person", confidence: 0.5,
              rect: CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.6)),
])
expectEqual(people.count, 2, "only persons pass the filter")
expectTrue(people.allSatisfy { $0.label == "person" }, "no other labels")

// MARK: - Event recording

let base = Date(timeIntervalSince1970: 3_000_000)
func at3(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

var events = ConversationCaptureModel()
events.addLine("Nice to meet you", at: at3(1))
events.addLine("   ", at: at3(2))
let firstSighting = events.addSighting(photoIndex: 0, at: at3(3))
events.addLine("Third floor now", at: at3(4))
let secondSighting = events.addSighting(photoIndex: nil, at: at3(5))

expectEqual(events.events.count, 4, "blank lines record no event")
expectEqual(events.events[0].kind, .speech, "first event is speech")
expectEqual(events.events[0].text, "Nice to meet you", "speech text is trimmed")
expectEqual(events.events[0].timestamp, at3(1), "speech carries its timestamp")
expectEqual(events.events[1].kind, .sighting, "second event is a sighting")
expectEqual(events.events[1].photoIndex, 0, "sighting carries its photo index")
expectEqual(events.events[1].text, "", "sighting has no text")
expectEqual(events.events[3].photoIndex, nil, "a failed crop records a nil index")
expectEqual(events.note, "Nice to meet you\nThird floor now",
            "note still joins the speech lines")

// A badge that arrives after the sighting was recorded.
let late = Badge(name: "Sarah Chen", rawLines: ["Sarah Chen"], source: .onDevice)
events.updateBadge(eventID: firstSighting, badge: late)
expectEqual(events.events[1].badge?.name, "Sarah Chen", "late badge lands on its event")
expectEqual(events.events[3].badge, nil, "other sightings are untouched")

// Unknown id is a no-op.
events.updateBadge(eventID: UUID(), badge: nil)
expectEqual(events.events[1].badge?.name, "Sarah Chen", "unknown id leaves badges alone")
expectTrue(secondSighting != firstSighting, "each sighting gets its own id")

// addSighting records an event on its own - no snap-gate call needed. It does
// NOT make the capture worth saving: `hasContent` is the spoken lines plus the
// snap gate, and a sighting touches neither.
var snapsOnly = ConversationCaptureModel()
_ = snapsOnly.addSighting(photoIndex: 0, at: at3(0))
expectTrue(snapsOnly.events.count == 1, "sighting recorded without a snap gate call")
expectTrue(!snapsOnly.hasContent, "a sighting alone is not content worth saving")

// recordSnap (the gate) and addSighting (the record) are deliberately
// separate calls - the gate never appends an event by itself, and
// addSighting never consults the gate.
var gateAndEvents = ConversationCaptureModel(maxPhotos: 1, minSnapGap: 100)
expectTrue(gateAndEvents.recordSnap(at: 0), "first snap allowed by the gate")
expectEqual(gateAndEvents.events.count, 0, "recordSnap alone never appends an event")
expectTrue(!gateAndEvents.recordSnap(at: 1), "second snap refused by the cap")
_ = gateAndEvents.addSighting(photoIndex: nil, at: at3(0))
expectEqual(gateAndEvents.events.count, 1,
            "addSighting records regardless of the gate's refusal")

// MARK: - Portraits ride along with the badge
//
// The badge and its portrait both arrive after the sighting is recorded -
// OCR lands whenever it lands - so they are attached together.

var portraitModel = ConversationCaptureModel()
let portraitEvent = portraitModel.addSighting(photoIndex: 0)
portraitModel.updateBadge(
    eventID: portraitEvent,
    badge: Badge(name: "Sarah Chen", rawLines: ["Sarah Chen"], source: .onDevice),
    portraitIndex: 3
)
expectEqual(portraitModel.events.last?.badge?.name, "Sarah Chen",
            "the badge is attached")
expectEqual(portraitModel.events.last?.portraitIndex, 3,
            "the portrait index is attached")

// No portrait is the common case - a conference lanyard has no photo on it.
var noPortrait = ConversationCaptureModel()
let plainEvent = noPortrait.addSighting(photoIndex: 0)
noPortrait.updateBadge(
    eventID: plainEvent,
    badge: Badge(name: "Sam", rawLines: ["Sam"], source: .onDevice),
    portraitIndex: nil
)
expectTrue(noPortrait.events.last?.portraitIndex == nil,
           "a badge with no portrait stores no index")

// An unknown event id stays a no-op.
noPortrait.updateBadge(eventID: UUID(), badge: nil, portraitIndex: 9)
expectEqual(noPortrait.events.count, 1, "an unknown id changes nothing")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
