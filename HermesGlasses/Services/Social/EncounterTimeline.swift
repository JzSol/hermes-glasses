//
// EncounterTimeline.swift
//
// Stored events -> the rows the review screen draws. Pure Foundation,
// tested standalone in tests/timeline/.
//
// Grouping happens HERE, at render time, and never at save time. A badge
// that arrives from the deferred assist pass ten seconds after the
// recording ended changes what should be grouped; if the grouping had
// been baked into storage there would be no correct moment to redo it.
//

import Foundation

struct EncounterTimeline: Equatable {
    /// `.singleNote` is only ever produced by the legacy path - a
    /// "remember this person" capture is two facts, and rendering it as a
    /// timeline would be worse than the screen it replaced.
    enum Kind: Equatable { case singleNote, conversation }

    struct Row: Identifiable, Equatable {
        enum Content: Equatable {
            case sighting(photoFilenames: [String], badge: Badge?)
            case speech(text: String)
        }

        /// String rather than UUID so the legacy path can mint stable ids
        /// from the encounter's own id instead of fresh random ones.
        let id: String
        let timestamp: Date
        let content: Content

        var frameCount: Int {
            if case .sighting(let files, _) = content { return files.count }
            return 0
        }
    }

    let kind: Kind
    let rows: [Row]

    static func build(_ encounter: Encounter) -> EncounterTimeline {
        guard !encounter.events.isEmpty else { return legacy(encounter) }
        return EncounterTimeline(kind: .conversation, rows: group(encounter.events))
    }

    // MARK: - Grouping

    private static func group(_ events: [EncounterEvent]) -> [Row] {
        let ordered = events.enumerated()
            .sorted { lhs, rhs in
                lhs.element.timestamp == rhs.element.timestamp
                    ? lhs.offset < rhs.offset
                    : lhs.element.timestamp < rhs.element.timestamp
            }
            .map(\.element)

        var rows: [Row] = []
        var rowForKey: [String: Int] = [:]

        for event in ordered {
            switch event.kind {
            case .speech:
                rows.append(Row(
                    id: event.id.uuidString, timestamp: event.timestamp,
                    content: .speech(text: event.text)
                ))

            case .sighting:
                let key = event.badge?.groupKey
                if let key, let existing = rowForKey[key] {
                    rows[existing] = merge(rows[existing], with: event)
                    continue
                }
                if let key { rowForKey[key] = rows.count }
                rows.append(Row(
                    id: event.id.uuidString, timestamp: event.timestamp,
                    content: .sighting(
                        photoFilenames: event.photoFilenames, badge: event.badge
                    )
                ))
            }
        }
        return rows
    }

    /// Fold a later sighting of the same person into its first row: keep
    /// the earliest timestamp and id, gather the photos, and keep whichever
    /// badge came from the more trustworthy source.
    private static func merge(_ row: Row, with event: EncounterEvent) -> Row {
        guard case .sighting(let files, let existing) = row.content else { return row }
        let incoming = event.badge
        let winner = (incoming?.source.rank ?? -1) > (existing?.source.rank ?? -1)
            ? incoming : existing
        return Row(
            id: row.id, timestamp: row.timestamp,
            content: .sighting(
                photoFilenames: files + event.photoFilenames, badge: winner
            )
        )
    }

    // MARK: - Legacy

    /// Entries written before the timeline existed, and every single-shot
    /// "remember this person" capture. No data migration - they simply
    /// render.
    private static func legacy(_ encounter: Encounter) -> EncounterTimeline {
        var rows: [Row] = []
        if !encounter.photoFilenames.isEmpty {
            rows.append(Row(
                id: "\(encounter.id.uuidString)-photos",
                timestamp: encounter.timestamp,
                content: .sighting(
                    photoFilenames: encounter.photoFilenames, badge: nil
                )
            ))
        }
        if !encounter.note.isEmpty {
            rows.append(Row(
                id: "\(encounter.id.uuidString)-note",
                timestamp: encounter.timestamp,
                content: .speech(text: encounter.note)
            ))
        }
        let kind: Kind = encounter.photoFilenames.count > 1 ? .conversation : .singleNote
        return EncounterTimeline(kind: kind, rows: rows)
    }
}
