//
// ConversationCapture.swift
//
// Pure state for a conversation-capture session ("record this
// conversation"): every finalized utterance becomes a transcript line, and
// dwell-fired person snaps are gated so one long chat doesn't fill the
// store with near-duplicate photos. Foundation + CoreGraphics only (uses
// Detection) so tests/conversation compiles it with plain swiftc.
//
// The camera/STT plumbing lives in HermesSessionViewModel; this type only
// decides what to keep.
//

import Foundation
import CoreGraphics

struct ConversationCaptureModel {
    /// Hard cap on photos per session - a two-hour dinner should not
    /// produce fifty pictures.
    let maxPhotos: Int
    /// Minimum seconds between kept snaps. The dwell tracker already
    /// prevents re-fires while the reticle stays on one person; this gates
    /// the look-away-look-back re-fires.
    let minSnapGap: TimeInterval

    private(set) var lines: [String] = []
    private(set) var snapCount = 0
    private var lastSnapAt: TimeInterval?

    /// The timeline as it accumulates. Speech and sightings interleaved in
    /// the order they happened; photos are still indices, because filenames
    /// don't exist until EncounterStore writes them.
    private(set) var events: [CapturedEvent] = []

    init(maxPhotos: Int = 12, minSnapGap: TimeInterval = 10) {
        self.maxPhotos = maxPhotos
        self.minSnapGap = minSnapGap
    }

    /// Append a finalized utterance. Blank utterances are dropped - they
    /// record neither a line nor an event.
    mutating func addLine(_ text: String, at timestamp: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
        events.append(CapturedEvent(
            kind: .speech, timestamp: timestamp, text: trimmed
        ))
    }

    /// The whole conversation as one note, in spoken order.
    var note: String { lines.joined(separator: "\n") }

    /// True when ending the session has something worth saving.
    var hasContent: Bool { !lines.isEmpty || snapCount > 0 }

    /// Ask permission to keep a dwell-fired snap; records it when granted.
    /// Refused when inside the gap or at the photo cap.
    mutating func recordSnap(at time: TimeInterval) -> Bool {
        guard snapCount < maxPhotos else { return false }
        if let last = lastSnapAt, time - last < minSnapGap { return false }
        lastSnapAt = time
        snapCount += 1
        return true
    }

    /// Record a sighting the snap gate already approved. Returns the event's
    /// id so a badge read that finishes later can find it again.
    ///
    /// `photoIndex` is nil when the crop failed: the sighting still happened
    /// and is still worth a row.
    @discardableResult
    mutating func addSighting(
        photoIndex: Int?, at timestamp: Date = Date()
    ) -> UUID {
        let event = CapturedEvent(
            kind: .sighting, timestamp: timestamp, photoIndex: photoIndex
        )
        events.append(event)
        return event.id
    }

    /// Attach a badge that arrived after its sighting was recorded - OCR
    /// runs off the main actor and lands whenever it lands. The portrait
    /// arrives with it, since both come out of the same badge crop. Unknown
    /// ids are a no-op.
    mutating func updateBadge(
        eventID: UUID, badge: Badge?, portraitIndex: Int? = nil
    ) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[index].badge = badge
        if let portraitIndex { events[index].portraitIndex = portraitIndex }
    }

    /// Person-only filter, applied at the detection boundary so the dwell
    /// tracker never locks onto a chair.
    static func people(_ detections: [Detection]) -> [Detection] {
        detections.filter { $0.label == "person" }
    }
}
