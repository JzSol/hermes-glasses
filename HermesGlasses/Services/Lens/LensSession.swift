//
// LensSession.swift
//
// One saved Lens (Object Snap) session: the per-object log captured while
// the Lens screen was open. Foundation only so tests compile it standalone.
//

import Foundation

struct LensSession: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    var entries: [Entry]

    /// One logged object: its YOLO label, total look-time, look count, and
    /// the crop filename inside photos/ ("" when the crop failed to save).
    struct Entry: Codable, Equatable {
        let label: String
        let totalLookTime: TimeInterval
        let lookCount: Int
        let photoFilename: String
    }
}
