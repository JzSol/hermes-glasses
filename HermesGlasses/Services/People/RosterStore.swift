//
// RosterStore.swift
//
// On-disk store for the lookup roster: photos as files in a photos/
// directory, the index as one roster.json. Plain Foundation - no database,
// no network, nothing leaves the phone.
//
// The contract is EncounterStore's, deliberately, because that contract is
// already proven in this codebase: memory is the source of truth and is
// updated synchronously, the bytes follow on one serial queue in order, and
// reads that touch the filesystem go through that queue too, so a photo
// written a moment ago is readable now. The queue is STATIC because
// ordering has to hold across instances - the Settings screen and the
// Lookup app each open their own store over the same directory.
//
// The only write path is `replaceAll`. An import replaces the roster
// wholesale, which is why there is no merge logic here to get wrong: either
// the new roster lands complete, or the old one survives untouched.
//

import Foundation
import os

final class RosterStore: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "roster"
    )

    private let rootURL: URL
    private let photosURL: URL
    private let indexURL: URL

    /// Guards `people` and `imported`. Every mutation lands here
    /// synchronously, so the next `all()` already sees it - only the bytes
    /// are deferred.
    private let lock = NSLock()
    private var people: [RosterPerson] = []
    private var imported: Date?

    private static let diskQueue = DispatchQueue(
        label: "com.flowsxr.hermesglasses.roster.disk", qos: .utility
    )

    private struct Index: Codable {
        var people: [RosterPerson]
        var importedAt: Date?
    }

    /// - Parameter directory: root for this store. Defaults to
    ///   Application Support/Roster; tests pass a temp directory.
    init(directory: URL? = nil) {
        let root = directory ?? Self.defaultDirectory()
        rootURL = root
        photosURL = root.appendingPathComponent("photos", isDirectory: true)
        indexURL = root.appendingPathComponent("roster.json")
        createDirectories()
        // On the disk queue, so an index another instance queued a moment
        // ago is on disk before it is read.
        let loaded = Self.diskQueue.sync { Self.loadIndex(at: indexURL, logger: logger) }
        people = loaded.people
        imported = loaded.importedAt
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Roster", isDirectory: true)
    }

    private func createDirectories() {
        for url in [rootURL, photosURL] {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        }
    }

    private static func loadIndex(at url: URL, logger: Logger) -> Index {
        guard let data = try? Data(contentsOf: url) else {
            return Index(people: [], importedAt: nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Index.self, from: data)
        } catch {
            logger.error("roster index unreadable: \(error.localizedDescription)")
            return Index(people: [], importedAt: nil)
        }
    }

    // MARK: - Reads

    /// Everyone, sorted by name - the order every screen wants.
    func all() -> [RosterPerson] {
        lock.withLock { people }.sorted { $0.name < $1.name }
    }

    func person(id: UUID) -> RosterPerson? {
        lock.withLock { people.first { $0.id == id } }
    }

    var count: Int { lock.withLock { people.count } }

    var photoCount: Int {
        lock.withLock { people.reduce(0) { $0 + $1.photoFilenames.count } }
    }

    /// How many people can actually be matched by face. Never assume this
    /// equals `count`: a portrait whose face Vision cannot find imports
    /// perfectly happily and matches nobody, and the difference is invisible
    /// until that person is standing in front of the wearer.
    var matchableCount: Int {
        lock.withLock { people.filter(\.isMatchable).count }
    }

    var importedAt: Date? { lock.withLock { imported } }

    /// The model identity the stored embeddings came from, if any. Compared
    /// against the bundled embedder to detect a model swap.
    var storedModelID: String? {
        lock.withLock { people.compactMap(\.modelID).first }
    }

    /// Read on the disk queue like EncounterStore's photo reads: bytes
    /// written a moment ago may still be queued, and a thumbnail that comes
    /// back nil because it was 5 ms early is a bug the user sees as a lost
    /// photo.
    func photoData(filename: String) -> Data? {
        Self.diskQueue.sync {
            try? Data(contentsOf: photosURL.appendingPathComponent(filename))
        }
    }

    func photoURL(filename: String) -> URL {
        photosURL.appendingPathComponent(filename)
    }

    // MARK: - Writes

    /// Replace the whole roster. `photos` is keyed by the filenames the
    /// people reference. The photos directory is emptied first, so a
    /// re-import cannot leave orphans of the previous roster behind.
    func replaceAll(_ newPeople: [RosterPerson], photos: [String: Data]) {
        let stamp = Date()
        lock.withLock {
            people = newPeople
            imported = stamp
        }
        let photosURL = self.photosURL
        let indexURL = self.indexURL
        let logger = self.logger
        Self.diskQueue.async {
            // Empty photos/ rather than remove it - the directory is created
            // once at init and every read path assumes it exists.
            let existing = (try? FileManager.default.contentsOfDirectory(
                at: photosURL, includingPropertiesForKeys: nil
            )) ?? []
            for url in existing { try? FileManager.default.removeItem(at: url) }

            for (name, data) in photos {
                do {
                    try data.write(to: photosURL.appendingPathComponent(name))
                } catch {
                    logger.error("roster photo \(name) failed: \(error.localizedDescription)")
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(
                    Index(people: newPeople, importedAt: stamp)
                )
                try data.write(to: indexURL, options: .atomic)
            } catch {
                logger.error("roster index write failed: \(error.localizedDescription)")
            }
        }
    }

    func removeAll() {
        replaceAll([], photos: [:])
        lock.withLock { imported = nil }
        let indexURL = self.indexURL
        Self.diskQueue.async {
            try? FileManager.default.removeItem(at: indexURL)
        }
    }
}
