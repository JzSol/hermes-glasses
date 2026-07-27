//
// EncounterEvent.swift
//
// The timeline's unit of record. A conversation capture is a stream of
// these: someone was seen (photo, maybe a name off their badge), or
// something was said. Foundation-only so the parser, the timeline builder
// and the capture model all unit-test standalone.
//
// Events are stored RAW - never pre-grouped. EncounterTimeline groups them
// at render time, which is what lets a badge that arrives after the
// recording ended regroup the timeline by itself.
//

import Foundation

/// A name tag, as read off someone. `rawLines` is always what OCR actually
/// saw, so a bad parse stays recoverable.
struct Badge: Codable, Equatable {
    /// Where the text came from. Ranked, because merging two sightings of
    /// the same person has to pick one.
    enum Source: String, Codable {
        case onDevice, assisted, manual

        var rank: Int {
            switch self {
            case .manual: return 2
            case .onDevice: return 1
            case .assisted: return 0
            }
        }
    }

    var name: String?
    var title: String?
    var org: String?
    var rawLines: [String]
    var source: Source

    init(
        name: String? = nil, title: String? = nil, org: String? = nil,
        rawLines: [String] = [], source: Source = .onDevice
    ) {
        self.name = name
        self.title = title
        self.org = org
        self.rawLines = rawLines
        self.source = source
    }

    /// "Radiology · Auckland City Hospital". Nil when there is neither.
    var subtitle: String? {
        let parts = [title, org]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The merge key: lowercased, punctuation stripped, whitespace
    /// collapsed. Nil when there is no name - and a nil key never merges
    /// with anything, which is the whole safety property here.
    var groupKey: String? {
        guard let name else { return nil }
        let scalars = name.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let collapsed = String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

/// One stored moment in an encounter.
struct EncounterEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case sighting, speech }

    let id: UUID
    let kind: Kind
    let timestamp: Date
    /// `.speech`: what was said. `.sighting`: empty.
    var text: String
    /// `.sighting`: crops in capture order, cover first. May be empty when
    /// the photo write failed - the sighting still happened.
    var photoFilenames: [String]
    /// `.sighting`: the name tag, when one could be read.
    var badge: Badge?

    init(
        id: UUID = UUID(), kind: Kind, timestamp: Date, text: String = "",
        photoFilenames: [String] = [], badge: Badge? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
        self.photoFilenames = photoFilenames
        self.badge = badge
    }

    static func speech(
        _ text: String, at timestamp: Date, id: UUID = UUID()
    ) -> EncounterEvent {
        EncounterEvent(id: id, kind: .speech, timestamp: timestamp, text: text)
    }

    static func sighting(
        photoFilenames: [String] = [], badge: Badge? = nil, at timestamp: Date,
        id: UUID = UUID()
    ) -> EncounterEvent {
        EncounterEvent(
            id: id, kind: .sighting, timestamp: timestamp,
            photoFilenames: photoFilenames, badge: badge
        )
    }

    // MARK: - Derived legacy fields

    /// The transcript, for `Encounter.note`. Speech only, in order.
    static func derivedNote(_ events: [EncounterEvent]) -> String {
        events
            .filter { $0.kind == .speech }
            .map(\.text)
            .joined(separator: "\n")
    }

    /// Every photo, for `Encounter.photoFilenames`, in sighting order.
    static func derivedPhotoFilenames(_ events: [EncounterEvent]) -> [String] {
        events
            .filter { $0.kind == .sighting }
            .flatMap(\.photoFilenames)
    }
}

/// An event as it exists mid-capture, before the store has assigned
/// filenames. `photoIndex` points into the capture's photo array.
struct CapturedEvent: Equatable {
    let id: UUID
    let kind: EncounterEvent.Kind
    let timestamp: Date
    var text: String
    /// Nil for speech, and for a sighting whose crop failed.
    var photoIndex: Int?
    var badge: Badge?

    init(
        id: UUID = UUID(), kind: EncounterEvent.Kind, timestamp: Date,
        text: String = "", photoIndex: Int? = nil, badge: Badge? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
        self.photoIndex = photoIndex
        self.badge = badge
    }
}
