//
// Encounter.swift
//
// One entry on the People screen: a spoken note plus glasses photos.
// Originally one person = one photo; conversation capture saves several
// people into a single entry, so photos are a list. Foundation-only value
// type so EncounterStore unit-tests standalone.
//

import Foundation

struct Encounter: Codable, Identifiable, Equatable {
    let id: UUID
    /// Transcribed note. May be empty when the note timed out - the photo
    /// alone is still worth keeping, and the note can be typed in later.
    var note: String
    let timestamp: Date
    /// Filenames inside the store's photos directory, in capture order.
    /// Empty when every capture failed (note-only encounter).
    var photoFilenames: [String]
    /// The timeline. Empty for entries written before it existed, and for
    /// single-shot "remember this person" captures - `EncounterTimeline`
    /// synthesises rows from `note`/`photoFilenames` in that case.
    var events: [EncounterEvent]
    /// The recording this capture's transcript came from, inside the store's
    /// recordings directory. Nil for encounters saved before recording
    /// existed, for "remember this person" (which records nothing), and when
    /// the recorder could not open a file.
    ///
    /// Kept after transcription on purpose: on-device recognition is the
    /// weakest link in this feature, and the audio is the only thing that
    /// makes a better transcript possible later without asking the wearer to
    /// have the conversation again.
    var audioFilename: String?

    /// The cover photo - what rows and single-photo call sites show.
    var photoFilename: String? { photoFilenames.first }

    init(
        id: UUID = UUID(),
        note: String,
        timestamp: Date,
        photoFilenames: [String] = [],
        events: [EncounterEvent] = [],
        audioFilename: String? = nil
    ) {
        self.id = id
        self.note = note
        self.timestamp = timestamp
        self.photoFilenames = photoFilenames
        self.events = events
        self.audioFilename = audioFilename
    }

    // MARK: - Codable (with pre-multi-photo migration)

    private enum CodingKeys: String, CodingKey {
        case id, note, timestamp, photoFilenames, photoFilename, events
        case audioFilename
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        note = try c.decode(String.self, forKey: .note)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        if let list = try c.decodeIfPresent([String].self, forKey: .photoFilenames) {
            photoFilenames = list
        } else if let single = try c.decodeIfPresent(String.self, forKey: .photoFilename) {
            // Index written before conversation capture existed.
            photoFilenames = [single]
        } else {
            photoFilenames = []
        }
        // Absent on every index written before the timeline existed.
        events = try c.decodeIfPresent([EncounterEvent].self, forKey: .events) ?? []
        // Absent on every index written before capture recorded audio.
        audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(note, forKey: .note)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(photoFilenames, forKey: .photoFilenames)
        try c.encode(events, forKey: .events)
        try c.encodeIfPresent(audioFilename, forKey: .audioFilename)
    }
}
