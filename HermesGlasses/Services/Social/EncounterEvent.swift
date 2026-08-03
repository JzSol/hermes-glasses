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
import CoreGraphics

/// A name tag, as read off someone. `rawLines` is always what OCR actually
/// saw, so a bad parse stays recoverable.
struct Badge: Codable, Equatable {
    /// Where the text came from. Ranked, because merging two sightings of
    /// the same person has to pick one.
    enum Source: String, Codable {
        case onDevice, assisted, manual, barcode

        var rank: Int {
            switch self {
            case .manual: return 3
            // A decoded barcode is not a reading of a badge, it IS the
            // badge's own data. It loses only to a human correction.
            case .barcode: return 2
            case .onDevice: return 1
            case .assisted: return 0
            }
        }
    }

    /// What kind of badge the detector saw. Display data ONLY - this must
    /// never become a grouping key. Grouping is by badge text.
    enum Kind: String, Codable {
        case conferenceLanyard, corporateID, clinicalID, handheldID

        /// The detector's class label, exactly as exported by ultralytics.
        /// Unknown labels are not an error: a model retrained with extra
        /// classes must degrade to "a badge, kind unknown".
        init?(detectorLabel: String) {
            switch detectorLabel {
            case "conference_lanyard": self = .conferenceLanyard
            case "corporate_id": self = .corporateID
            case "clinical_id": self = .clinicalID
            case "handheld_id": self = .handheldID
            default: return nil
            }
        }

        var displayName: String {
            switch self {
            case .conferenceLanyard: return "Conference badge"
            case .corporateID: return "Staff ID"
            case .clinicalID: return "Clinical ID"
            case .handheldID: return "ID card"
            }
        }
    }

    var name: String?
    var title: String?
    var org: String?
    var rawLines: [String]
    var source: Source
    /// Set when the detector localised the badge. All four are optional so
    /// the synthesized decoder reads an encounters.json written before
    /// badge detection existed - no migration shim needed.
    var kind: Kind?
    /// A QR/barcode's raw contents. Kept even when it parsed to nothing
    /// useful: an opaque attendee id is still the thing printed on the tag.
    var barcodePayload: String?
    /// The portrait printed on an ID card, in the store's photos/ directory.
    /// Never sent off the phone. Nil unless `badge_portraits_enabled`.
    var portraitFilename: String?
    /// Where the badge was, in unit coordinates of the person crop
    /// (origin TOP-LEFT). Kept so a later pass can re-crop the badge
    /// without re-running the detector.
    var badgeRect: CGRect?

    init(
        name: String? = nil, title: String? = nil, org: String? = nil,
        rawLines: [String] = [], source: Source = .onDevice,
        kind: Kind? = nil, barcodePayload: String? = nil,
        portraitFilename: String? = nil, badgeRect: CGRect? = nil
    ) {
        self.name = name
        self.title = title
        self.org = org
        self.rawLines = rawLines
        self.source = source
        self.kind = kind
        self.barcodePayload = barcodePayload
        self.portraitFilename = portraitFilename
        self.badgeRect = badgeRect
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

    /// This badge, carrying forward the fields only the on-device pass can
    /// produce. Badge assist replies with TEXT; it never sees the detector's
    /// box, the badge kind or the portrait, so writing its result over an
    /// existing badge would silently drop them. Values already set on self
    /// always win - this fills gaps, it does not overwrite.
    func preservingLocalFields(from previous: Badge?) -> Badge {
        guard let previous else { return self }
        var merged = self
        merged.kind = kind ?? previous.kind
        merged.barcodePayload = barcodePayload ?? previous.barcodePayload
        merged.portraitFilename = portraitFilename ?? previous.portraitFilename
        merged.badgeRect = badgeRect ?? previous.badgeRect
        return merged
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
