//
// LensLogAggregator.swift
//
// Pure aggregation for the Lens object log: folds per-snap and per-look
// events into one entry per YOLO label (total look-time, look count).
// Foundation only - no UIKit - so tests/lenslog compiles it with swiftc.
//

import Foundation

/// One aggregated log entry, image-free. Images are held by the view model
/// keyed by label; this type carries only the numbers so it stays testable.
struct LensLogEntryData: Equatable {
    let label: String
    var totalLookTime: TimeInterval
    var lookCount: Int
    var firstSeen: Date
    var lastSeen: Date
}

/// Accumulates snaps and completed looks into per-label entries. `lookCount`
/// counts snaps (each snapped gaze == one look); `totalLookTime` sums the
/// duration of each completed look.
struct LensLogAggregator {
    private var byLabel: [String: LensLogEntryData] = [:]

    var isEmpty: Bool { byLabel.isEmpty }

    /// A dwell fired a snap on `label`. Creates the entry or bumps its count.
    mutating func recordSnap(label: String, at date: Date) {
        if var entry = byLabel[label] {
            entry.lookCount += 1
            entry.lastSeen = date
            byLabel[label] = entry
        } else {
            byLabel[label] = LensLogEntryData(
                label: label, totalLookTime: 0, lookCount: 1,
                firstSeen: date, lastSeen: date
            )
        }
    }

    /// A completed look on `label` lasted `duration`. A look without a prior
    /// snap is ignored (cannot normally happen - a snap always precedes it).
    mutating func recordLook(label: String, duration: TimeInterval, at date: Date) {
        guard var entry = byLabel[label] else { return }
        entry.totalLookTime += duration
        entry.lastSeen = date
        byLabel[label] = entry
    }

    /// Entries sorted by total look-time, longest first.
    func entries() -> [LensLogEntryData] {
        byLabel.values.sorted { $0.totalLookTime > $1.totalLookTime }
    }
}
