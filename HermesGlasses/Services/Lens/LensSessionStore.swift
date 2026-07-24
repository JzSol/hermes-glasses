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

    private let lock = NSLock()
    private var sessions: [LensSession] = []

    /// - Parameter directory: root for this store. Defaults to Application
    ///   Support/LensSessions; tests pass a temp directory.
    init(directory: URL? = nil) {
        let root = directory ?? Self.defaultDirectory()
        rootURL = root
        photosURL = root.appendingPathComponent("photos", isDirectory: true)
        indexURL = root.appendingPathComponent("sessions.json")
        createDirectories()
        sessions = loadIndex()
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

    func photoData(for entry: LensSession.Entry) -> Data? {
        guard !entry.photoFilename.isEmpty else { return nil }
        return try? Data(
            contentsOf: photosURL.appendingPathComponent(entry.photoFilename)
        )
    }

    // MARK: - Writes

    /// Save a session. A crop that fails to write is dropped (empty filename),
    /// never fatal - a missing picture beats a lost session.
    @discardableResult
    func save(
        startedAt: Date, endedAt: Date, entries: [LensSessionInput]
    ) -> LensSession {
        let id = UUID()
        var saved: [LensSession.Entry] = []
        for (index, input) in entries.enumerated() {
            var filename = ""
            if let photo = input.photo {
                let name = "\(id.uuidString)-\(index).jpg"
                do {
                    try photo.write(
                        to: photosURL.appendingPathComponent(name), options: .atomic
                    )
                    filename = name
                } catch {
                    logger.error("Crop write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            saved.append(LensSession.Entry(
                label: input.label, totalLookTime: input.totalLookTime,
                lookCount: input.lookCount, photoFilename: filename
            ))
        }
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
        for entry in removed?.entries ?? [] where !entry.photoFilename.isEmpty {
            try? FileManager.default.removeItem(
                at: photosURL.appendingPathComponent(entry.photoFilename)
            )
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

    private func writeIndex() {
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
