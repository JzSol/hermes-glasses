//
// LensSessionStore.swift
//
// On-disk store for Lens object-log sessions: crops as JPEGs in a photos/
// directory, the index as one sessions.json. Plain Foundation, mirrors
// EncounterStore - nothing leaves the phone.
//

import Foundation
import os

/// What the view model hands the store per logged object.
struct LensSessionInput {
    let label: String
    let totalLookTime: TimeInterval
    let lookCount: Int
    let photo: Data?
}

final class LensSessionStore: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "lens-sessions"
    )

    private let rootURL: URL
    private let photosURL: URL
    private let indexURL: URL

    /// Guards `sessions`. Mutations land here synchronously; only the bytes
    /// are deferred.
    private let lock = NSLock()
    private var sessions: [LensSession] = []

    /// Every byte this type writes or deletes goes through this one queue, in
    /// order. Static, so ordering holds across instances over the same
    /// directory - a second store must not read an index the first one still
    /// has queued. Its own queue, not `EncounterStore`'s: different directory,
    /// and a lens save has no reason to wait behind a capture's photos.
    private static let diskQueue = DispatchQueue(
        label: "com.flowsxr.hermesglasses.lens-sessions.disk", qos: .utility
    )

    /// - Parameter directory: root for this store. Defaults to Application
    ///   Support/LensSessions; tests pass a temp directory.
    init(directory: URL? = nil) {
        let root = directory ?? Self.defaultDirectory()
        rootURL = root
        photosURL = root.appendingPathComponent("photos", isDirectory: true)
        indexURL = root.appendingPathComponent("sessions.json")
        createDirectories()
        // On the disk queue, so an index another instance queued a moment ago
        // is on disk before it is read.
        sessions = Self.diskQueue.sync { loadIndex() }
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LensSessions", isDirectory: true)
    }

    // MARK: - Reads

    /// All sessions, newest first.
    func all() -> [LensSession] {
        lock.withLock { sessions }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Read on the disk queue: a crop saved a moment ago may still be queued,
    /// and a thumbnail that comes back nil because the bytes are late reads
    /// as a lost photo.
    func photoData(for entry: LensSession.Entry) -> Data? {
        guard !entry.photoFilename.isEmpty else { return nil }
        return Self.diskQueue.sync {
            try? Data(
                contentsOf: photosURL.appendingPathComponent(entry.photoFilename)
            )
        }
    }

    // MARK: - Writes

    /// Save a session. A crop that fails to write costs the picture, never
    /// the session - the failure is logged from the disk queue and the entry
    /// stands with a filename nothing answers to.
    @discardableResult
    func save(
        startedAt: Date, endedAt: Date, entries: [LensSessionInput]
    ) -> LensSession {
        let id = UUID()
        var saved: [LensSession.Entry] = []
        // Filenames are decided here; the bytes follow on the disk queue. A
        // write that fails leaves a filename with no file, which `photoData`
        // already reads as nil.
        var pending: [(name: String, data: Data)] = []
        for (index, input) in entries.enumerated() {
            var filename = ""
            if let photo = input.photo {
                let name = "\(id.uuidString)-\(index).jpg"
                pending.append((name, photo))
                filename = name
            }
            saved.append(LensSession.Entry(
                label: input.label, totalLookTime: input.totalLookTime,
                lookCount: input.lookCount, photoFilename: filename
            ))
        }
        writePhotos(pending)
        let session = LensSession(
            id: id, startedAt: startedAt, endedAt: endedAt, entries: saved
        )
        lock.withLock { sessions.append(session) }
        writeIndex()
        return session
    }

    func delete(id: UUID) {
        let removed: LensSession? = lock.withLock {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
            return sessions.remove(at: index)
        }
        // Nothing removed, nothing to rewrite - an unknown id must not cost a
        // full index re-encode.
        guard let removed else { return }

        // On the disk queue (so a crop still queued for these files is
        // written before it is deleted) but synchronously: Delete is done
        // when it returns, files and all.
        Self.diskQueue.sync {
            for entry in removed.entries where !entry.photoFilename.isEmpty {
                try? FileManager.default.removeItem(
                    at: photosURL.appendingPathComponent(entry.photoFilename)
                )
            }
        }
        writeIndex()
    }

    // MARK: - Disk

    private func createDirectories() {
        for url in [rootURL, photosURL] {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        }
    }

    private func loadIndex() -> [LensSession] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([LensSession].self, from: data)
        } catch {
            logger.error("Index unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Queue the crop bytes for a save. Ordered ahead of the index write that
    /// follows, so the index never names a file that isn't there yet.
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
                    logger.error("Crop write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Persist the whole index.
    ///
    /// The snapshot is taken INSIDE the queued block, not at the call site:
    /// snapshotting first let two mutators enqueue out of order and persist
    /// the older state last, silently losing the newer edit.
    private func writeIndex() {
        Self.diskQueue.async { [self] in
            let snapshot = lock.withLock { sessions }
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
