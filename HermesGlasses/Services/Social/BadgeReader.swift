//
// BadgeReader.swift
//
// Getting name-tag text out of a person crop, two ways: on-device with
// Vision (free, offline, the default), and - only when the user has opted
// in - through the configured AI provider for the badges Vision could not
// read.
//
// Both are best-effort by contract. Every failure means "no badge", never
// an error the wearer sees, and never a reason not to save an encounter.
//

import Foundation
import UIKit
import Vision

/// On-device text recognition over a person crop.
enum BadgeReader {
    /// Below this, the "text" is usually a fold in a shirt.
    static let minimumConfidence: Float = 0.4

    /// Recognised lines, top of the badge first. Empty when nothing
    /// readable - which at glasses range is the common case.
    ///
    /// The `Task.detached` is DELIBERATE, not ceremony - do not "simplify"
    /// it away. `VNImageRequestHandler.perform` is synchronous and takes
    /// tens of milliseconds at `.accurate`, and every caller here is on the
    /// main actor. A bare `nonisolated func … async` only runs off the main
    /// actor by virtue of SE-0338 plus this project's `SWIFT_VERSION = 5.0`;
    /// under Swift 6.2+ (or `SWIFT_APPROACHABLE_CONCURRENCY = YES`) it
    /// becomes `nonisolated(nonsending)`, inherits the caller's executor,
    /// and turns every person sighting into a main-thread OCR hang with
    /// nothing pointing back at this file. Detaching puts the guarantee in
    /// the code instead of in the build settings.
    static func readLines(from image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let confidence = minimumConfidence

        return await Task.detached(priority: .utility) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Badges are proper nouns. Correction turns surnames into
            // dictionary words, which is worse than not reading the badge
            // at all.
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[Hermes] badge: vision failed - \(error.localizedDescription)")
                return []
            }

            let observations = request.results ?? []
            return observations
                // Vision's origin is bottom-left, so the highest maxY is the
                // topmost line - and the name is nearly always printed first.
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= confidence
                    else { return nil }
                    let text = candidate.string
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
        }.value
    }

    /// Read and parse in one step. Nil when there is no legible badge.
    static func readBadge(from image: UIImage) async -> Badge? {
        BadgeParser.parse(await readLines(from: image), source: .onDevice)
    }
}

extension BadgeAssist {
    /// One assisted read. Throws so the caller can ask `isFatal` whether to
    /// keep going.
    static func read(photoJPEG: Data, client: DirectClient) async throws -> Badge? {
        let reply = try await client.askOneShot(
            systemPrompt: systemPrompt, userText: userText,
            photoJPEG: photoJPEG, timeout: timeout
        )
        return parse(reply)
    }
}
