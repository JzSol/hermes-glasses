//
// EncounterStore.swift
//
// On-disk store for social encounters: photos as JPEGs in a photos/
// directory, the index as one encounters.json. Plain Foundation - no
// database, no network, nothing leaves the phone.
//
// The whole index is kept in memory and rewritten on every mutation. A
// day of networking is tens of entries, so the simplicity is worth more
// than incremental writes.
//
// Memory is the source of truth and is updated synchronously; the bytes
// follow on one serial queue, in order. Reads that touch the filesystem go
// through that queue too, so a photo saved a moment ago is readable now.
//

import Foundation
import os

final class EncounterStore: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "encounters"
    )

    private let rootURL: URL
    private let photosURL: URL
    private let recordingsURL: URL
    private let indexURL: URL

    /// Guards `encounters`. Every mutation lands here synchronously, so the
    /// caller's `encounterRevision` bump and the next `all()` already see it
    /// - only the bytes are deferred.
    private let lock = NSLock()
    private var encounters: [Encounter] = []

    /// Every byte this type writes or deletes goes through this one queue, in
    /// order. Saves are kicked off from the main actor and a capture ends with
    /// up to twelve JPEGs plus a pretty-printed index re-encode; doing that
    /// inline stalled the UI at the exact moment the wearer is told "Saved".
    ///
    /// Static, not per-instance, because ordering has to hold ACROSS
    /// instances: a second store opened over the same directory (the People
    /// screen, a test reopening the index) reads files an earlier instance
    /// may still have queued, and one shared queue is what makes that read
    /// see them.
    private static let diskQueue = DispatchQueue(
        label: "com.flowsxr.hermesglasses.encounters.disk", qos: .utility
    )

    /// - Parameter directory: root for this store. Defaults to
    ///   Application Support/Encounters; tests pass a temp directory.
    init(directory: URL? = nil) {
        let root = directory ?? Self.defaultDirectory()
        rootURL = root
        photosURL = root.appendingPathComponent("photos", isDirectory: true)
        recordingsURL = root.appendingPathComponent("recordings", isDirectory: true)
        indexURL = root.appendingPathComponent("encounters.json")
        createDirectories()
        // On the disk queue, so an index another instance queued a moment ago
        // is on disk before it is read.
        encounters = Self.diskQueue.sync { loadIndex() }
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Encounters", isDirectory: true)
    }

    // MARK: - Reads

    /// All encounters, newest first.
    func all() -> [Encounter] {
        lock.withLock { encounters }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// The cover photo (first capture).
    ///
    /// Read on the disk queue like every other photo read: a JPEG saved a
    /// moment ago may still be queued behind the index write, and a thumbnail
    /// that comes back nil because the bytes are 5 ms late is a bug the user
    /// sees as a lost photo.
    func photoData(for encounter: Encounter) -> Data? {
        guard let filename = encounter.photoFilename else { return nil }
        return Self.diskQueue.sync {
            try? Data(contentsOf: photosURL.appendingPathComponent(filename))
        }
    }

    /// All photos, in capture order. Files that went missing are skipped.
    func photoDatas(for encounter: Encounter) -> [Data] {
        Self.diskQueue.sync {
            encounter.photoFilenames.compactMap { filename in
                try? Data(contentsOf: photosURL.appendingPathComponent(filename))
            }
        }
    }

    /// One photo by filename - what the timeline rows and the assist pass
    /// use, since both address photos per-event rather than per-encounter.
    func photoData(filename: String) -> Data? {
        Self.diskQueue.sync {
            try? Data(contentsOf: photosURL.appendingPathComponent(filename))
        }
    }

    /// Where a capture in progress should write its audio. The encounter does
    /// not exist yet at that point, so recordings are staged under their own
    /// id and adopted by `attachRecording` once the encounter is saved.
    func stagingRecordingURL(id: UUID = UUID()) -> URL {
        recordingsURL.appendingPathComponent("\(id.uuidString).wav")
    }

    /// The recording behind an encounter, if one was kept.
    func recordingURL(for encounter: Encounter) -> URL? {
        guard let filename = encounter.audioFilename else { return nil }
        let url = recordingsURL.appendingPathComponent(filename)
        return Self.diskQueue.sync {
            FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // MARK: - Writes

    /// Save a new encounter. The photo is optional: a failed capture still
    /// produces a note-only entry rather than losing the encounter.
    @discardableResult
    func save(note: String, photo: Data?, timestamp: Date = Date()) -> Encounter {
        save(note: note, photos: photo.map { [$0] } ?? [], timestamp: timestamp)
    }

    /// Save an encounter with any number of photos (conversation capture).
    /// A photo that fails to write costs the picture, never the encounter -
    /// the failure is logged from the disk queue and the entry stands.
    @discardableResult
    func save(note: String, photos: [Data], timestamp: Date = Date()) -> Encounter {
        let id = UUID()
        // Filenames are decided here and now - the encounter handed back has
        // to be complete - while the bytes go out on the disk queue. A write
        // that fails therefore leaves a filename with no file behind it, and
        // every read path already treats a missing photo as nil.
        var filenames: [String] = []
        var pending: [(name: String, data: Data)] = []
        for (index, photo) in photos.enumerated() {
            let name = photos.count == 1
                ? "\(id.uuidString).jpg"
                : "\(id.uuidString)-\(index).jpg"
            filenames.append(name)
            pending.append((name, photo))
        }
        writePhotos(pending)

        let encounter = Encounter(
            id: id,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: timestamp,
            photoFilenames: filenames
        )
        lock.withLock { encounters.append(encounter) }
        writeIndex()
        return encounter
    }

    /// Save a capture as an ordered event stream. Events reference photos by
    /// index; filenames are assigned here, because only the store knows
    /// them. `note` and `photoFilenames` are written as derived values so
    /// every reader that predates the timeline keeps working.
    @discardableResult
    func save(
        events: [CapturedEvent], photos: [Data], timestamp: Date = Date()
    ) -> Encounter {
        let id = UUID()

        // Named here, written on the disk queue: the events an event stream
        // resolves to must be complete before this returns, and a capture's
        // twelve JPEGs are not something to make the main actor wait for.
        var filenames: [String] = []
        var pending: [(name: String, data: Data)] = []
        for (index, photo) in photos.enumerated() {
            let name = "\(id.uuidString)-\(index).jpg"
            filenames.append(name)
            pending.append((name, photo))
        }
        writePhotos(pending)

        let resolved: [EncounterEvent] = events.map { event in
            var files: [String] = []
            if let index = event.photoIndex, index >= 0, index < filenames.count {
                files = [filenames[index]]
            }
            return EncounterEvent(
                id: event.id, kind: event.kind, timestamp: event.timestamp,
                text: event.text, photoFilenames: files, badge: event.badge
            )
        }

        let encounter = Encounter(
            id: id,
            note: EncounterEvent.derivedNote(resolved),
            timestamp: timestamp,
            photoFilenames: EncounterEvent.derivedPhotoFilenames(resolved),
            events: resolved
        )
        lock.withLock { encounters.append(encounter) }
        writeIndex()
        return encounter
    }

    /// Adopt a staged recording into the store under the encounter's id.
    /// Returns the final URL, or nil when there was nothing to adopt.
    ///
    /// The file is MOVED, not copied - a conversation can run for an hour and
    /// duplicating it to rename it would briefly double the disk it needs.
    @discardableResult
    func attachRecording(encounterID: UUID, from staged: URL) -> URL? {
        let filename = "\(encounterID.uuidString).wav"
        let destination = recordingsURL.appendingPathComponent(filename)

        // On the disk queue for ordering, but synchronously: this is a rename,
        // not a copy, and the caller is handed the destination to transcribe
        // from the moment it returns.
        let moved: Bool = Self.diskQueue.sync {
            guard FileManager.default.fileExists(atPath: staged.path) else { return false }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staged, to: destination)
                return true
            } catch {
                logger.error("Recording move failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard moved else { return nil }

        lock.withLock {
            guard let index = encounters.firstIndex(where: { $0.id == encounterID })
            else { return }
            encounters[index].audioFilename = filename
        }
        writeIndex()
        return destination
    }

    /// Replace a capture's speech events wholesale with a better transcript.
    ///
    /// Sightings are left exactly where they are: they carry the photos and
    /// badges, and their timestamps are the only thing tying a face to a
    /// moment in the conversation. Only the speech is rewritten, spread
    /// evenly across the span the live transcript covered so the interleaving
    /// with sightings stays approximately honest.
    ///
    /// A no-op when `lines` is empty - a failed transcription must never
    /// erase the transcript the live path did manage to hear.
    func replaceTranscript(encounterID: UUID, lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.withLock {
            guard let index = encounters.firstIndex(where: { $0.id == encounterID })
            else { return }

            let events = encounters[index].events
            let speech = events.filter { $0.kind == .speech }
            let start = speech.first?.timestamp
                ?? events.first?.timestamp
                ?? encounters[index].timestamp
            let end = speech.last?.timestamp
                ?? events.last?.timestamp
                ?? start
            let span = max(0, end.timeIntervalSince(start))
            let step = lines.count > 1 ? span / Double(lines.count - 1) : 0

            let rebuilt = lines.enumerated().map { offset, line in
                EncounterEvent.speech(
                    line, at: start.addingTimeInterval(step * Double(offset))
                )
            }

            let kept = events.filter { $0.kind != .speech }
            let merged = (kept + rebuilt).sorted { $0.timestamp < $1.timestamp }
            encounters[index].events = merged
            encounters[index].note = EncounterEvent.derivedNote(merged)
        }
        writeIndex()
    }

    /// Replace ONE event's badge wholesale. This is the machine-read path:
    /// the deferred assist pass, which has a complete badge (name, title,
    /// org, rawLines) for one specific sighting. A manual correction is NOT
    /// this - it renames every event a timeline row was merged from and
    /// keeps their raw lines, which is `updateBadgeName` below.
    /// Unknown ids are a no-op.
    func update(encounterID: UUID, eventID: UUID, badge: Badge?) {
        lock.withLock {
            guard let entry = encounters.firstIndex(where: { $0.id == encounterID }),
                  let event = encounters[entry].events.firstIndex(where: { $0.id == eventID })
            else { return }
            encounters[entry].events[event].badge = badge
        }
        writeIndex()
    }

    /// Rename every event a timeline row was built from. Each event keeps
    /// its OWN rawLines/title/org - only the name is unified, which is what
    /// makes the row regroup as one person instead of splitting.
    func updateBadgeName(encounterID: UUID, eventIDs: [UUID], name: String?) {
        lock.withLock {
            guard let entry = encounters.firstIndex(where: { $0.id == encounterID })
            else { return }
            for eventID in eventIDs {
                guard let event = encounters[entry].events
                    .firstIndex(where: { $0.id == eventID }) else { continue }
                var badge = encounters[entry].events[event].badge
                    ?? Badge(rawLines: [], source: .manual)
                badge.name = name
                badge.source = .manual
                encounters[entry].events[event].badge = badge
            }
        }
        writeIndex()
    }

    /// Edit a note after the fact (the People detail screen).
    func update(id: UUID, note: String) {
        lock.withLock {
            guard let index = encounters.firstIndex(where: { $0.id == id }) else { return }
            encounters[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        writeIndex()
    }

    func delete(id: UUID) {
        let removed: Encounter? = lock.withLock {
            guard let index = encounters.firstIndex(where: { $0.id == id }) else { return nil }
            return encounters.remove(at: index)
        }
        // Nothing removed, nothing to rewrite - an unknown id must not cost a
        // full index re-encode.
        guard let removed else { return }

        // On the disk queue (so a photo still queued for these very files is
        // written before it is deleted, not after) but synchronously: Delete
        // is done when it returns, files and all.
        Self.diskQueue.sync {
            for filename in removed.photoFilenames {
                try? FileManager.default.removeItem(
                    at: photosURL.appendingPathComponent(filename)
                )
            }
            if let audio = removed.audioFilename {
                // Deleting an encounter must take its recording with it -
                // leaving an orphaned hour of conversation on disk is the
                // opposite of what the person pressing Delete asked for.
                try? FileManager.default.removeItem(
                    at: recordingsURL.appendingPathComponent(audio)
                )
            }
        }
        writeIndex()
    }

    // MARK: - Disk

    private func createDirectories() {
        for url in [rootURL, photosURL, recordingsURL] {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        }
    }

    private func loadIndex() -> [Encounter] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Encounter].self, from: data)
        } catch {
            // A corrupt index must not wedge the app on every launch; the
            // photos stay on disk either way.
            logger.error("Index unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Queue the photo bytes for a save. Ordered ahead of the index write
    /// that follows, so the index never names a file that isn't there yet.
    private func writePhotos(_ photos: [(name: String, data: Data)]) {
        guard !photos.isEmpty else { return }
        Self.diskQueue.async { [logger, photosURL] in
            for photo in photos {
                do {
                    try photo.data.write(
                        to: photosURL.appendingPathComponent(photo.name),
                        options: .atomic
                    )
                } catch {
                    logger.error("Photo write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Persist the whole index.
    ///
    /// The snapshot is taken INSIDE the queued block, not at the call site:
    /// snapshotting first let two mutators enqueue out of order and persist
    /// the older state last, silently losing the newer edit. Encoding from
    /// current memory at write time makes every write at least as new as the
    /// mutation that asked for it, and the last one always current.
    private func writeIndex() {
        Self.diskQueue.async { [self] in
            let snapshot = lock.withLock { encounters }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: indexURL, options: .atomic)
            } catch {
                logger.error("Index write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
