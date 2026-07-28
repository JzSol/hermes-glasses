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
    /// TWO passes, merged in order: the magnified lanyard band first, then
    /// the whole crop. The band pass is what actually reads badges - see
    /// `BadgeRegion` for why the whole-person crop returns nothing - and the
    /// full pass is the cheap safety net for a tag worn high, clipped to a
    /// sleeve, or held up in a hand. Band lines come first because
    /// `BadgeParser` takes the first name-shaped line it finds, and the band
    /// is the region we actually believe.
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
            var lines: [String] = []
            var seen = Set<String>()

            for candidateImage in [magnifiedBand(of: cgImage), cgImage] {
                guard let candidateImage else { continue }
                for line in recognize(candidateImage, confidence: confidence)
                where seen.insert(line.lowercased()).inserted {
                    lines.append(line)
                }
            }
            return lines
        }.value
    }

    /// One synchronous Vision pass. Caller is responsible for being off the
    /// main actor.
    private static func recognize(
        _ image: CGImage, confidence: Float
    ) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Badges are proper nouns. Correction turns surnames into
        // dictionary words, which is worse than not reading the badge
        // at all.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
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
    }

    /// The lanyard band of a person crop, magnified so its text has enough
    /// pixels to recognise. Nil when the crop is too small or degenerate to
    /// slice - the caller still runs the whole-crop pass.
    private static func magnifiedBand(of image: CGImage) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        let band = BadgeRegion.band
        let pixelRect = CGRect(
            x: band.minX * width, y: band.minY * height,
            width: band.width * width, height: band.height * height
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect)
        else { return nil }

        let target = BadgeRegion.upscaledSize(
            for: CGSize(width: pixelRect.width, height: pixelRect.height)
        )
        guard target.width > pixelRect.width else { return cropped }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let magnified = renderer.image { context in
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: cropped).draw(
                in: CGRect(origin: .zero, size: target)
            )
        }
        return magnified.cgImage ?? cropped
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
