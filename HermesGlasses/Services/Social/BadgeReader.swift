//
// BadgeReader.swift
//
// Getting name-tag information out of a person crop. Three ways, in
// descending order of trust: a barcode decoded off the badge, on-device
// Vision text recognition, and - only when the user has opted in, and only
// after the encounter is on disk - the configured AI provider.
//
// The badge is LOCATED first (BadgeDetector); the band (BadgeRegion) is the
// fallback, run when localisation is unavailable, found nothing, OR found a
// box that named nobody. That last case matters once a model ships: a
// false-positive detection (a shirt pocket clearing the confidence floor)
// must not strand OCR on a region with no text when the band would still
// have found the name. The band is the floor: it is what shipped before
// detection existed, and removing it - or letting a bad detection shut it
// out - would make a badge worn somewhere the model got wrong worse off
// than it was.
//
// Both paths are best-effort by contract. Every failure means "no badge",
// never an error the wearer sees, and never a reason not to save an
// encounter.
//

import Foundation
import UIKit
import Vision
import os

/// On-device text recognition over a person crop.
enum BadgeReader {
    private static let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "badge"
    )

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
            logger.error("Vision text request failed: \(error.localizedDescription, privacy: .public)")
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

        return magnified(cropped)
    }

    /// A detected badge box as a magnified CGImage, ready for text and
    /// barcode passes. Nil when the box does not survive conversion to
    /// pixels - a detection at the very edge of a tiny crop.
    private static func magnifiedBadge(
        of image: CGImage, box: BadgeBox
    ) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard let pixelRect = BadgeCrop.pixelRect(
            for: BadgeCrop.padded(box.rect), in: size
        ), let cropped = image.cropping(to: pixelRect) else { return nil }
        return magnified(cropped)
    }

    /// Upscale a crop to the size BadgeRegion measured as readable. Returns
    /// the input unchanged when it is already big enough.
    private static func magnified(_ image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let target = BadgeCrop.upscaledSize(for: size)
        guard target.width > size.width else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let output = renderer.image { context in
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
        }
        return output.cgImage ?? image
    }

    /// Read the badge worn by the person in this crop.
    ///
    /// Two strategies, tried in order, with the band run as a fallback in
    /// TWO cases rather than one:
    ///
    /// 1. **Detected.** `BadgeDetector` localises the badge; its box is
    ///    padded, magnified, and read for text, a barcode and a kind. A
    ///    barcode wins over text when both land, because it decoded rather
    ///    than inferred. If this names someone, it is returned immediately -
    ///    the band never runs, so a successful detection costs nothing
    ///    extra.
    /// 2. **The band.** Runs when there is no model or no detection - the
    ///    pre-existing floor - AND ALSO when a detected box named nobody: a
    ///    false-positive detection, or a real badge the crop couldn't read,
    ///    must not shut the band out of a region it might still read.
    ///    `BadgeParser.preferred` picks whichever of the two actually names
    ///    someone, and when the band wins it still carries forward the
    ///    detected badge's `kind`/`badgeRect`/`barcodePayload` - the band
    ///    pass produces none of those itself.
    ///
    /// Returns a badge whenever EITHER pass located one, even when nothing
    /// on it could be read - `name` is nil but `kind` and `badgeRect` are
    /// set. That is deliberate: "there is a tag here I could not read" is
    /// worth recording, and it is what badge assist selects on
    /// (`badge?.name == nil`, not `badge == nil`).
    static func readBadge(from image: UIImage) async -> Badge? {
        guard let cgImage = image.cgImage else { return nil }

        if let box = BadgeCrop.best(await BadgeDetector.shared.detect(cgImage)) {
            let detected = await readDetected(box: box, in: cgImage)
            guard detected.name == nil else { return detected }
            // The detector found something but nothing on it was legible -
            // run the band as insurance, strictly on this failure branch so
            // a successful detection never pays for it.
            let fallback = BadgeParser.parse(
                await readLines(from: image), source: .onDevice
            )
            return BadgeParser.preferred(detected: detected, fallback: fallback)
        }
        return BadgeParser.parse(await readLines(from: image), source: .onDevice)
    }

    /// The detected path: everything we can get off one located badge. The
    /// merge itself is pure and lives in `BadgeParser.merge` - see its doc
    /// comment for the barcode/OCR precedence rules and why it moved there.
    private static func readDetected(
        box: BadgeBox, in cgImage: CGImage
    ) async -> Badge {
        let rect = BadgeCrop.padded(box.rect)
        let kind = Badge.Kind(detectorLabel: box.label)

        let read = await Task.detached(priority: .utility) {
            () -> (barcode: Badge?, lines: [String]) in
            guard let crop = magnifiedBadge(of: cgImage, box: box) else {
                return (nil, [])
            }
            // Both passes run on the SAME magnified crop - the barcode
            // needs the pixels as much as the text does.
            return (BarcodeReader.read(crop),
                    recognize(crop, confidence: minimumConfidence))
        }.value

        return BadgeParser.merge(
            barcode: read.barcode, lines: read.lines, kind: kind, rect: rect
        )
    }

    /// The image to send to badge assist. When the detector localised a
    /// badge, this is that badge magnified - far more legible per token
    /// than a head-to-knees crop, within the same 6-read cap. With no box
    /// it returns the original bytes unchanged, which is what assist sent
    /// before detection existed and is exactly the sighting assist is for.
    ///
    /// The saved portrait FILE is never attached here - this function only
    /// ever crops the sighting photo. But the crop IS the badge, and on an
    /// ID card the printed portrait is part of the badge, so when a badge
    /// carries one, its pixels can be inside what this sends.
    static func assistCrop(photoJPEG: Data, badgeRect: CGRect?) async -> Data {
        guard let badgeRect, let image = UIImage(data: photoJPEG),
              let cgImage = image.cgImage else { return photoJPEG }

        return await Task.detached(priority: .utility) { () -> Data in
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            guard let pixels = BadgeCrop.pixelRect(for: badgeRect, in: size),
                  let crop = cgImage.cropping(to: pixels),
                  let jpeg = UIImage(cgImage: magnified(crop)).jpegData(
                      compressionQuality: HermesCameraManager.jpegQuality
                  )
            else { return photoJPEG }
            return jpeg
        }.value
    }

    /// The portrait printed on a badge already located in this crop.
    /// Re-crops from `badgeRect` rather than re-running the detector -
    /// which is exactly what `Badge.badgeRect` is stored for.
    static func portrait(
        from image: UIImage, badgeRect: CGRect
    ) async -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .utility) { () -> Data? in
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            guard let pixels = BadgeCrop.pixelRect(for: badgeRect, in: size),
                  let crop = cgImage.cropping(to: pixels) else { return nil }
            return BadgePortrait.extract(from: magnified(crop))
        }.value
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
